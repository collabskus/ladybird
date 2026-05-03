# export.ps1
#
# 1. Writes Documentation/llm/context.NNN.txt — small, LLM-optimised chunks
#      - full file tree with metadata
#      - build/CI/config files only (NOT test fixtures, NOT vendored WPT data)
#      - each chunk ≤ 20 MB so every chunk fits in Claude's 30 MB upload limit
#
# 2. Writes Documentation/llm/dump.NNN.txt — full source dump in 25 MB chunks
#
# 3. Syncs with upstream and force-pushes to mine:
#      - fetch origin/master
#      - hard-reset local master to origin/master  (upstream always wins)
#      - restore our files on top (they were never in upstream, so no conflicts)
#      - commit + force-push to mine

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
} else {
    Write-Host "Output directory already exists: $outputDir"
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

Write-Host "Found $($trackedFiles.Count) tracked files (after exclusions)."

# ── Build metadata ────────────────────────────────────────────────────────────
$timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
$totalSize  = [long]0
$fileCount  = 0
$missingCnt = 0
$enc        = [System.Text.Encoding]::UTF8

$fileInfos = foreach ($rel in $trackedFiles) {
    $abs = Join-Path $repoRoot $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path $abs -PathType Leaf) {
        $info = Get-Item $abs
        $totalSize += $info.Length
        $fileCount++
        [PSCustomObject]@{ Rel=$rel; Abs=$abs; Size=$info.Length; Modified=$info.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"); Missing=$false }
    } else {
        $missingCnt++
        [PSCustomObject]@{ Rel=$rel; Abs=$abs; Size=0; Modified=""; Missing=$true }
    }
}
Write-Host ("Metadata: {0} files, {1:N0} bytes total." -f $fileCount, $totalSize)

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
$excludedPrefixes = @(
    'tests/',
    'userland/',
    'base/',
    'ports/',
    'toolchain/tarballs/',
    'toolchain/patches/',
    'vcpkg/',
    '.git/'
)

$contextFileSizeCap = 200KB

function Test-LlmRelevant([string]$rel, [long]$size) {
    $r = $rel.Replace('\','/').ToLowerInvariant()
    foreach ($pfx in $excludedPrefixes) { if ($r.StartsWith($pfx)) { return $false } }
    if ($size -gt $contextFileSizeCap) { return $false }

    $baseName = ($r -split '/')[-1]
    $alwaysNames = @(
        'cmakelists.txt','cmakepresets.json','vcpkg.json','vcpkg-configuration.json',
        'readme','readme.md','readme.txt','license','license.txt','copying',
        '.gitignore','.gitattributes','conanfile.txt','conanfile.py',
        'meson.build','configure.ac','makefile','justfile','toolchain'
    )
    if ($alwaysNames -contains $baseName) { return $true }

    $ext = [System.IO.Path]::GetExtension($r).ToLowerInvariant()
    $includeExts = @(
        '.md','.markdown','.rst',
        '.yml','.yaml',
        '.cmake',
        '.py',
        '.sh','.bash',
        '.ps1','.psm1',
        '.toml',
        '.ini','.cfg','.conf'
    )
    if ($includeExts -contains $ext) { return $true }

    if ($ext -eq '.json') {
        $jsonAllowed = @(
            'vcpkg.json','vcpkg-configuration.json','cmakepresets.json',
            'package.json','package-lock.json','tsconfig.json','.eslintrc.json','.prettierrc.json'
        )
        if ($jsonAllowed -contains $baseName) { return $true }
        if ($r.StartsWith('.github/')) { return $true }
        return $false
    }

    if ($ext -eq '.txt') {
        $txtAllowed = @(
            'cmakelists.txt','readme.txt','license.txt','copying.txt',
            'requirements.txt','constraints.txt','changelog.txt','changes.txt',
            'todo.txt','notes.txt','authors.txt','credits.txt','conanfile.txt','known_issues.txt'
        )
        if ($txtAllowed -contains $baseName) { return $true }
        $depth = ($r -split '/').Count
        if ($depth -le 3 -and -not ($r.Contains('/test'))) { return $true }
        return $false
    }

    $buildDirs = @('.github/','meta/','cmake/','toolchain/','scripts/','tools/','packaging/','documentation/')
    foreach ($bd in $buildDirs) { if ($r.StartsWith($bd)) { return $true } }

    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: context.NNN.txt
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Writing context chunks (LLM-optimised, ≤20 MB each)..."

$ctxIndex = 1
$ctxBytes = [long]0

function New-CtxPath([int]$idx) { Join-Path $outputDir ("context.{0:D3}.txt" -f $idx) }
function Open-CtxChunk([int]$idx) {
    $sw = [System.IO.StreamWriter]::new((New-CtxPath $idx), $false, $enc)
    Write-Host "  Opening context chunk: context.$($idx.ToString('D3')).txt"
    return $sw
}

$ctxSw = Open-CtxChunk $ctxIndex

function Write-Ctx([string]$line) {
    $lb = $enc.GetByteCount($line) + 2
    if (($script:ctxBytes + $lb) -gt $script:contextChunkMax) {
        $script:ctxSw.WriteLine("## [continued in next context chunk]")
        $script:ctxSw.Close()
        $script:ctxIndex++
        $script:ctxBytes = 0
        $script:ctxSw = Open-CtxChunk $script:ctxIndex
        $script:ctxSw.WriteLine("## [LADYBIRD CONTEXT — chunk $($script:ctxIndex) — continued]")
        $script:ctxSw.WriteLine("")
    }
    $script:ctxSw.WriteLine($line)
    $script:ctxBytes += $lb
}

Write-Ctx ("=" * 80)
Write-Ctx "LADYBIRD BROWSER — LLM CONTEXT DUMP"
Write-Ctx "Generated  : $timestamp"
Write-Ctx "Repo root  : $repoRoot"
Write-Ctx "Purpose    : Build-system, dependencies, CI/CD, and project structure"
Write-Ctx "             context for an LLM. Test fixtures excluded."
Write-Ctx ("=" * 80)
Write-Ctx ""
Write-Ctx ("=" * 80)
Write-Ctx "BUILD SYSTEM OVERVIEW"
Write-Ctx ("=" * 80)
Write-Ctx @"

CMake >= 3.30 + Ninja.  Third-party deps via vcpkg (manifest mode).

  python3 Meta/BuildVcpkg.py      # MUST run first — bootstraps vcpkg into Build/vcpkg
  cmake --preset Release          # configure (reads CMakePresets.json)
  cmake --build Build/release     # compile

Toolchain requirements
  - clang-21 / gcc-14 (C++23)
  - Python 3 venv     (Meta/ladybird.py build driver + Meta/BuildVcpkg.py)
  - nasm              (assembly in media/crypto — required by ffmpeg/skia)
  - ninja             (build backend)
  - Rust stable       (required by some vcpkg ports)
  - wasm-tools        (required by build)
  - CMake >= 3.30

Key vcpkg dependencies (vcpkg.json)
  - skia         2D graphics
  - ffmpeg       media decoding (audio/video) — requires nasm
  - curl         networking
  - openssl      TLS
  - harfbuzz     text shaping
  - icu          Unicode / i18n
  - libjpeg-turbo, libpng, libwebp, libavif   image codecs
  - simdutf      fast UTF conversion
  - zlib, brotli, zstd   compression
  - libxml2      XML

Linux UI  : Qt6 (qt6-base, qt6-tools, qt6-wayland)
macOS UI  : AppKit — Xcode 15+ or Homebrew llvm@21 required
Windows   : Native port in progress; WSL2 recommended

Meta/ladybird.py wraps all cmake targets (build/run/debug/test).
Meta/BuildVcpkg.py bootstraps vcpkg — run before cmake.
Meta/CMake/     contains custom CMake modules.
Toolchain/      contains vcpkg triplet files and compiler setup.
.github/        contains all CI/CD pipelines.
vcpkg binary cache: https://vcpkg-cache.app.ladybird.org/
"@
Write-Ctx ""

Write-Ctx ("=" * 80)
Write-Ctx "FULL FILE TREE  (* = content included below)"
Write-Ctx ("=" * 80)
Write-Ctx ("{0,-70} {1,12} {2,-24}" -f "PATH", "SIZE (B)", "LAST MODIFIED")
Write-Ctx ("{0,-70} {1,12} {2,-24}" -f ("-"*70), ("-"*12), ("-"*24))

foreach ($fi in $fileInfos) {
    $marker = if (Test-LlmRelevant $fi.Rel $fi.Size) { "*" } else { " " }
    if ($fi.Missing) {
        Write-Ctx ("{0}{1,-69} {2,12} {3,-24}" -f $marker, $fi.Rel, "[missing]", "")
    } else {
        Write-Ctx ("{0}{1,-69} {2,12} {3,-24}" -f $marker, $fi.Rel, $fi.Size, $fi.Modified)
    }
}
Write-Ctx ""
Write-Ctx ("Total: {0} files, {1:N0} bytes  |  * files have content below" -f $fileCount, $totalSize)
Write-Ctx ""

Write-Ctx ("=" * 80)
Write-Ctx "RELEVANT FILE CONTENTS"
Write-Ctx ("=" * 80)
Write-Ctx ""

$ctxIncluded = 0
$ctxSkipped  = 0

foreach ($fi in $fileInfos) {
    if (-not (Test-LlmRelevant $fi.Rel $fi.Size)) { $ctxSkipped++; continue }
    Write-Ctx ("=" * 80)
    Write-Ctx "FILE: $($fi.Rel)"
    if ($fi.Missing) {
        Write-Ctx "SIZE: [missing]"
        Write-Ctx ("-" * 80)
        Write-Ctx "[File not found on disk]"
    } else {
        Write-Ctx ("SIZE: $($fi.Size) bytes  |  LAST MODIFIED: $($fi.Modified)")
        Write-Ctx ("-" * 80)
        if (Test-BinaryFile $fi.Abs) {
            Write-Ctx "[Binary file – contents omitted]"
        } else {
            try { Write-Ctx ([System.IO.File]::ReadAllText($fi.Abs, $enc)) }
            catch { Write-Ctx "[Could not read: $_]" }
        }
    }
    Write-Ctx ""
    $ctxIncluded++
}

Write-Ctx ("=" * 80)
Write-Ctx ("END OF CONTEXT  –  $timestamp  –  chunk {0}" -f $ctxIndex)
Write-Ctx ("Included: {0} files  |  Omitted: {1}" -f $ctxIncluded, $ctxSkipped)
Write-Ctx ("=" * 80)
$ctxSw.Close()
$totalCtxChunks = $ctxIndex

$ctxSizes = @()
for ($i = 1; $i -le $totalCtxChunks; $i++) {
    $sz = (Get-Item (New-CtxPath $i)).Length
    $ctxSizes += $sz
    Write-Host ("  context.{0:D3}.txt : {1:N2} MB" -f $i, ($sz/1MB))
}
Write-Host ("Context written: {0} chunk(s), {1:N2} MB total, {2} files included" -f $totalCtxChunks, (($ctxSizes | Measure-Object -Sum).Sum/1MB), $ctxIncluded)

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: Full dump in 25 MB chunks
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Writing full source dump (chunked at 25 MB)..."

$dChunkIndex = 1
$dChunkBytes = [long]0

function New-DumpPath([int]$idx) { Join-Path $outputDir ("dump.{0:D3}.txt" -f $idx) }
function Open-DumpChunk([int]$idx) {
    $sw = [System.IO.StreamWriter]::new((New-DumpPath $idx), $false, $enc)
    Write-Host "  Opening chunk: dump.$($idx.ToString('D3')).txt"
    return $sw
}

$dSw = Open-DumpChunk $dChunkIndex

function Write-Dump([string]$line) {
    $lb = $enc.GetByteCount($line) + 2
    if (($script:dChunkBytes + $lb) -gt $script:dumpChunkMax) {
        $script:dSw.WriteLine("## [continued in next chunk]")
        $script:dSw.Close()
        $script:dChunkIndex++
        $script:dChunkBytes = 0
        $script:dSw = Open-DumpChunk $script:dChunkIndex
        $script:dSw.WriteLine("## [LADYBIRD FULL DUMP — chunk $($script:dChunkIndex) — continued]")
        $script:dSw.WriteLine("")
    }
    $script:dSw.WriteLine($line)
    $script:dChunkBytes += $lb
}

Write-Dump ("=" * 80)
Write-Dump "LADYBIRD FULL DUMP"
Write-Dump "Generated: $timestamp  |  Files: $fileCount  |  Size: $($totalSize.ToString('N0')) bytes"
Write-Dump ("=" * 80)
Write-Dump ""
Write-Dump "FILE TREE"
Write-Dump ("-" * 80)
Write-Dump ("{0,-70} {1,12} {2,-24}" -f "PATH","SIZE (B)","LAST MODIFIED")
Write-Dump ("{0,-70} {1,12} {2,-24}" -f ("-"*70),("-"*12),("-"*24))
foreach ($fi in $fileInfos) {
    if ($fi.Missing) { Write-Dump ("{0,-70} {1,12}" -f $fi.Rel, "[missing]") }
    else             { Write-Dump ("{0,-70} {1,12} {2,-24}" -f $fi.Rel, $fi.Size, $fi.Modified) }
}
Write-Dump ""
Write-Dump ("=" * 80)
Write-Dump "FILE CONTENTS"
Write-Dump ("=" * 80)
Write-Dump ""

$done = 0
foreach ($fi in $fileInfos) {
    Write-Dump ("=" * 80)
    Write-Dump "FILE: $($fi.Rel)"
    if ($fi.Missing) {
        Write-Dump ("-" * 80)
        Write-Dump "[File not found on disk]"
    } else {
        Write-Dump ("SIZE: $($fi.Size) bytes  |  LAST MODIFIED: $($fi.Modified)")
        Write-Dump ("-" * 80)
        if (Test-BinaryFile $fi.Abs) {
            Write-Dump "[Binary file – contents omitted]"
        } else {
            try {
                $content = [System.IO.File]::ReadAllText($fi.Abs, $enc)
                foreach ($cl in $content -split "`n") { Write-Dump $cl.TrimEnd("`r") }
            } catch { Write-Dump "[Could not read: $_]" }
        }
    }
    Write-Dump ""
    $done++
    if ($done % 1000 -eq 0) { Write-Host ("  ... {0}/{1} files (chunk {2})" -f $done, $fileCount, $dChunkIndex) }
}

Write-Dump ("=" * 80)
Write-Dump ("END OF FULL DUMP  –  $timestamp  –  {0} chunks" -f $dChunkIndex)
Write-Dump ("=" * 80)
$dSw.Close()
$totalDumpChunks = $dChunkIndex
Write-Host ("Full dump written: {0} chunk(s)" -f $totalDumpChunks)

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: Git — sync with upstream, commit our files, force-push to mine
#
# Strategy (replaces the problematic rebase loop):
#   1. Fetch origin/master
#   2. Hard-reset local master to origin/master  ← upstream always wins
#   3. Our files (export.ps1, Documentation/llm/**, .github/workflows/**)
#      are brand-new files that never existed in upstream, so they survive
#      the hard-reset untouched on disk (git reset --hard only resets tracked
#      files; our new files are untracked at this point)
#   4. Stage + commit our files on top of the fresh upstream HEAD
#   5. Force-push to mine
# ─────────────────────────────────────────────────────────────────────────────
Push-Location $repoRoot
try {

    # Build the list of our files
    $ourFiles = [System.Collections.Generic.List[string]]@("export.ps1")
    for ($i = 1; $i -le $totalCtxChunks;  $i++) { $ourFiles.Add("Documentation/llm/context.{0:D3}.txt" -f $i) }
    for ($i = 1; $i -le $totalDumpChunks; $i++) { $ourFiles.Add("Documentation/llm/dump.{0:D3}.txt"    -f $i) }

    # Also include any workflow files we own that are already tracked
    $trackedWorkflows = & git ls-files -- ".github/workflows/" 2>$null | Where-Object {
        $_ -match "collabskus"
    }
    if ($trackedWorkflows) { foreach ($f in $trackedWorkflows) { $ourFiles.Add($f) } }

    # ── Step 1: Fetch upstream ────────────────────────────────────────────────
    Write-Host ""
    Write-Host "Fetching from origin..."
    Invoke-Git @("fetch", "origin")

    # ── Step 2: Hard-reset to upstream ───────────────────────────────────────
    # This moves master to exactly origin/master.
    # Our files are NOT tracked by upstream so they stay on disk untouched.
    Write-Host "Resetting local master to origin/master (upstream wins)..."
    Invoke-Git @("reset", "--hard", "origin/master")
    Write-Host "Reset complete. Now at: $((Invoke-Git @('rev-parse','--short','HEAD')).Trim())"

    # ── Step 3: Stage our files ───────────────────────────────────────────────
    Write-Host ""
    Write-Host "Staging our files..."
    foreach ($f in $ourFiles) {
        $abs = Join-Path $repoRoot $f.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path $abs) {
            Invoke-Git @("add", "--", $f) | Out-Null
            Write-Host "  Staged: $f"
        }
    }

    # ── Step 4: Commit ────────────────────────────────────────────────────────
    $status = & git status --porcelain 2>&1
    if ($status) {
        Write-Host ""
        Write-Host "Committing our files..."
        Invoke-Git @("commit", "-m", "chore: update dump and export tooling [$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]")
        Write-Host "Committed."
    } else {
        Write-Host "Nothing to commit — our files match what is already in history."
    }

    # ── Step 5: Force-push to mine ────────────────────────────────────────────
    Write-Host ""
    Write-Host "Force-pushing to 'mine' (--force-with-lease)..."
    # Fetch mine first so --force-with-lease has fresh tracking data
    Invoke-GitSafe @("fetch", "mine") | Out-Null
    Invoke-Git @("push", "--force-with-lease", "mine", "master")
    Write-Host "Push complete."

} finally { Pop-Location }

Write-Host ""
Write-Host "export.ps1 finished successfully."
Write-Host ""
Write-Host "── Output summary ──────────────────────────────────────────────────"
Write-Host ("  context chunks : {0} x ≤20 MB  ({1} LLM files included)" -f $totalCtxChunks, $ctxIncluded)
Write-Host ("  full dump      : {0} x ≤25 MB" -f $totalDumpChunks)
Write-Host ""
Write-Host "  Upload context.001.txt (and .002 if present) to Claude Projects."
Write-Host "────────────────────────────────────────────────────────────────────"
