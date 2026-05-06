# export.ps1
#
# 1. Writes Documentation/llm/context.NNN.txt — small, LLM-optimised chunks
# 2. Writes Documentation/llm/dump.NNN.txt — full source dump
# 3. Commits our files, syncs with upstream, force-pushes to mine
# 4. WRAPPER: Runs every 4 hours continuously.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Loop Configuration
$sleepSeconds = 4 * 60 * 60  # 4 hours

while ($true) {
    Write-Host ("=" * 80)
    Write-Host "STARTING EXPORT CYCLE: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ("=" * 80)

    try {
        $contextChunkMax = 20MB
        $dumpChunkMax    = 25MB

        # ── Helpers ───────────────────────────────────────────────────────────────────
        function Invoke-Git {
            param([string[]]$GitArgs)
            $result = & git @GitArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE):`n$result" }
            return $result
        }
        function Invoke-GitSafe {
            param([string[]]$GitArgs)
            $result = & git @GitArgs 2>&1
            return [PSCustomObject]@{ Output = $result; ExitCode = $LASTEXITCODE }
        }

        # ── Paths ─────────────────────────────────────────────────────────────────────
        $repoRoot  = $PSScriptRoot
        $outputDir = Join-Path $repoRoot "Documentation" "llm"

        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            Write-Host "Created directory: $outputDir"
        }

        # Clean previous outputs
        $old = @(
            Get-ChildItem -Path $outputDir -Filter "dump.*.txt"    -ErrorAction SilentlyContinue
            Get-ChildItem -Path $outputDir -Filter "context.*.txt" -ErrorAction SilentlyContinue
        )
        if ($old.Count -gt 0) {
            $old | Remove-Item -Force
            Write-Host "Removed $($old.Count) previous output file(s)."
        }

        # ── Collect git-tracked files ─────────────────────────────────────────────────
        Write-Host "Collecting git-tracked files..."
        Push-Location $repoRoot
        try { $gitFiles = Invoke-Git @("ls-files", "--full-name") }
        finally { Pop-Location }

        $trackedFiles = $gitFiles | Where-Object {
            -not ($_.Replace('\','/').ToLowerInvariant().StartsWith("documentation/llm/"))
        } | Sort-Object

        # ── Build metadata ────────────────────────────────────────────────────────────
        $timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
        $totalSize  = [long]0
        $fileCount  = 0
        $enc        = [System.Text.Encoding]::UTF8

        $fileInfos = foreach ($rel in $trackedFiles) {
            $abs = Join-Path $repoRoot $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)
            if (Test-Path $abs -PathType Leaf) {
                $info = Get-Item $abs
                $totalSize += $info.Length
                $fileCount++
                [PSCustomObject]@{ Rel=$rel; Abs=$abs; Size=$info.Length; Modified=$info.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"); Missing=$false }
            } else {
                [PSCustomObject]@{ Rel=$rel; Abs=$abs; Size=0; Modified=""; Missing=$true }
            }
        }

        # ── Binary detection ──────────────────────────────────────────────────────────
        function Test-BinaryFile([string]$path) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($path)
                $sniff = [Math]::Min($bytes.Length, 8192)
                for ($i = 0; $i -lt $sniff; $i++) { if ($bytes[$i] -eq 0) { return $true } }
                return $false
            } catch { return $true }
        }

        # ── LLM relevance filter ──────────────────────────────────────────────────────
        $excludedPrefixes = @('tests/','userland/','base/','ports/','toolchain/tarballs/','toolchain/patches/','vcpkg/','.git/')
        $contextFileSizeCap = 200KB

        function Test-LlmRelevant([string]$rel, [long]$size) {
            $r = $rel.Replace('\','/').ToLowerInvariant()
            foreach ($pfx in $excludedPrefixes) { if ($r.StartsWith($pfx)) { return $false } }
            if ($size -gt $contextFileSizeCap) { return $false }
            $baseName = ($r -split '/')[-1]
            $alwaysNames = @('cmakelists.txt','cmakepresets.json','vcpkg.json','vcpkg-configuration.json','readme','readme.md','readme.txt','license','license.txt','copying','.gitignore','.gitattributes','conanfile.txt','conanfile.py','meson.build','configure.ac','makefile','justfile','toolchain')
            if ($alwaysNames -contains $baseName) { return $true }
            $ext = [System.IO.Path]::GetExtension($r).ToLowerInvariant()
            $includeExts = @('.md','.markdown','.rst','.yml','.yaml','.cmake','.py','.sh','.bash','.ps1','.psm1','.toml','.ini','.cfg','.conf')
            if ($includeExts -contains $ext) { return $true }
            if ($ext -eq '.json') {
                $jsonAllowed = @('vcpkg.json','vcpkg-configuration.json','cmakepresets.json','package.json','package-lock.json','tsconfig.json','.eslintrc.json','.prettierrc.json')
                if ($jsonAllowed -contains $baseName) { return $true }
                if ($r.StartsWith('.github/')) { return $true }
                return $false
            }
            if ($ext -eq '.txt') {
                $txtAllowed = @('cmakelists.txt','readme.txt','license.txt','copying.txt','requirements.txt','constraints.txt','changelog.txt','changes.txt','todo.txt','notes.txt','authors.txt','credits.txt','conanfile.txt','known_issues.txt')
                if ($txtAllowed -contains $baseName) { return $true }
                $depth = ($r -split '/').Count
                if ($depth -le 3 -and -not ($r.Contains('/test'))) { return $true }
                return $false
            }
            $buildDirs = @('.github/','meta/','cmake/','toolchain/','scripts/','tools/','packaging/','documentation/')
            foreach ($bd in $buildDirs) { if ($r.StartsWith($bd)) { return $true } }
            return $false
        }

        # ── SECTION 1: context.NNN.txt ────────────────────────────────────────────────
        $ctxIndex = 1
        $ctxBytes = [long]0
        $ctxTotal = 0
        function New-CtxPath([int]$idx) { Join-Path $outputDir ("context.{0:D3}.txt" -f $idx) }
        function Open-CtxChunk([int]$idx) { return [System.IO.StreamWriter]::new((New-CtxPath $idx), $false, $enc) }
        $ctxSw = Open-CtxChunk $ctxIndex
        function Write-Ctx([string]$line) {
            $lb = $enc.GetByteCount($line) + 2
            if (($script:ctxBytes + $lb) -gt $script:contextChunkMax) {
                $script:ctxSw.WriteLine("## [continued in next context chunk]")
                $script:ctxSw.Close()
                $script:ctxIndex++
                $script:ctxBytes = 0
                $script:ctxSw = Open-CtxChunk $script:ctxIndex
            }
            $script:ctxSw.WriteLine($line)
            $script:ctxBytes += $lb
        }

        Write-Ctx "LADYBIRD BROWSER — LLM CONTEXT DUMP — Generated: $timestamp"
        $ctxIncluded = 0
        foreach ($fi in $fileInfos) {
            if (-not (Test-LlmRelevant $fi.Rel $fi.Size)) { continue }
            Write-Ctx ("=" * 80); Write-Ctx "FILE: $($fi.Rel)"
            if ($fi.Missing) { Write-Ctx "[File not found on disk]" }
            else {
                if (Test-BinaryFile $fi.Abs) { Write-Ctx "[Binary file omitted]" }
                else { try { Write-Ctx ([System.IO.File]::ReadAllText($fi.Abs, $enc)) } catch { Write-Ctx "[Read Error]" } }
            }
            $ctxIncluded++
        }
        $ctxSw.Close()
        $totalCtxChunks = $ctxIndex

        # ── SECTION 2: Full dump ──────────────────────────────────────────────────────
        $dChunkIndex = 1
        $dChunkBytes = [long]0
        function New-DumpPath([int]$idx) { Join-Path $outputDir ("dump.{0:D3}.txt" -f $idx) }
        function Open-DumpChunk([int]$idx) { return [System.IO.StreamWriter]::new((New-DumpPath $idx), $false, $enc) }
        $dSw = Open-DumpChunk $dChunkIndex
        function Write-Dump([string]$line) {
            $lb = $enc.GetByteCount($line) + 2
            if (($script:dChunkBytes + $lb) -gt $script:dumpChunkMax) {
                $script:dSw.Close()
                $script:dChunkIndex++
                $script:dChunkBytes = 0
                $script:dSw = Open-DumpChunk $script:dChunkIndex
            }
            $script:dSw.WriteLine($line)
            $script:dChunkBytes += $lb
        }

        foreach ($fi in $fileInfos) {
            Write-Dump "FILE: $($fi.Rel)"
            if (-not $fi.Missing -and -not (Test-BinaryFile $fi.Abs)) {
                try { $content = [System.IO.File]::ReadAllText($fi.Abs, $enc); foreach ($cl in $content -split "`n") { Write-Dump $cl.TrimEnd("`r") } } catch {}
            }
        }
        $dSw.Close()
        $totalDumpChunks = $dChunkIndex

        # ── SECTION 3: Git ────────────────────────────────────────────────────────────
        Push-Location $repoRoot
        try {
            $ourFiles = [System.Collections.Generic.List[string]]@("export.ps1")
            for ($i = 1; $i -le $totalCtxChunks;  $i++) { $ourFiles.Add("Documentation/llm/context.{0:D3}.txt" -f $i) }
            for ($i = 1; $i -le $totalDumpChunks; $i++) { $ourFiles.Add("Documentation/llm/dump.{0:D3}.txt"    -f $i) }

            foreach ($f in $ourFiles) { if (Test-Path (Join-Path $repoRoot $f)) { Invoke-Git @("add", "--", $f) | Out-Null } }

            $status = & git status --porcelain 2>&1
            if ($status) {
                Invoke-Git @("commit", "-m", "chore: update dump and export tooling [$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]")
            }

            Invoke-Git @("fetch", "origin")
            $mergeBase = Invoke-GitSafe @("merge-base", "--is-ancestor", "origin/master", "HEAD")
            if ($mergeBase.ExitCode -ne 0) {
                Invoke-Git @("merge", "-s", "ours", "--no-edit", "-m", "chore: merge upstream [$(Get-Date)]", "origin/master")
            }

            Invoke-GitSafe @("fetch", "mine") | Out-Null
            Invoke-Git @("push", "--force-with-lease", "mine", "master")
            Write-Host "Cycle complete. Push successful."
        } finally { Pop-Location }

    } catch {
        Write-Warning "An error occurred during this cycle: $($_.Exception.Message)"
    }

    Write-Host "Sleeping for 4 hours until next update..."
    Start-Sleep -Seconds $sleepSeconds
}
