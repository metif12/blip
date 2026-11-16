$ErrorActionPreference = 'Stop'

# blip builds against ONE compiler: the commit pinned in
# .github/workflows/ci.yml. Building against "whatever vlang/v master is this
# morning" is how an install works on Friday and fails on Monday -- 1123
# commits upstream changed the checker out from under vlib/blip. So V and its
# vc bootstrap are pinned to exactly the pair CI builds, and the same two
# commits appear in both install scripts and CI.
#
# Keep these two lines in sync with ci.yml.
$VCommit  = '74be97a2d7bd1fce4150abc749a2e64b21d9d082'
$VCCommit = '0027130e9850c9946fa2c21e9004f13d8e593595'

$BlipDir = if ($env:BLIP_INSTALL_DIR) { $env:BLIP_INSTALL_DIR } else { "$HOME\.blip" }
$VDir    = if ($env:BLIP_V_DIR)       { $env:BLIP_V_DIR }       else { "$HOME\.blip-v" }
$Repo    = 'https://github.com/metif12/blip.git'

Write-Host "==> Installing blip to $BlipDir"

if (-not (Test-Path $BlipDir)) {
    git clone $Repo $BlipDir
}

Set-Location $BlipDir
git pull --ff-only

# The bootstrap compiles vc/v.c with a C compiler. Saying so up front beats a
# bare "failed to find executable cc" three minutes in.
$hasCc = $false
foreach ($cc in 'cc', 'gcc', 'clang') {
    if (Get-Command $cc -ErrorAction SilentlyContinue) { $hasCc = $true; break }
}
if (-not $hasCc) {
    Write-Host "==> ERROR: no C compiler found."
    Write-Host "    blip builds itself and V with gcc. The easiest on Windows:"
    Write-Host "      scoop install gcc"
    Write-Host "    or install TDM-GCC / w64devkit and put it on PATH."
    exit 1
}

function Install-PinnedV {
    # Already built, and built from THIS pin? Cheap check via a marker file:
    # `v version` prints a version string, not a commit, and is no identity.
    $marker = Join-Path $VDir '.blip-commit'
    if ((Test-Path (Join-Path $VDir 'v.exe')) -and (Test-Path $marker) `
            -and ((Get-Content $marker -Raw).Trim() -eq $VCommit)) {
        return
    }
    Write-Host "==> V not found (or not the pinned build). Building V $VCommit..."
    Write-Host "    This compiles V from source once and takes a few minutes."
    if (Test-Path $VDir) { Remove-Item -Recurse -Force $VDir }
    git init -q $VDir
    Set-Location $VDir
    git remote add origin https://github.com/vlang/v.git
    git fetch -q --depth 1 origin $VCommit
    git checkout -q FETCH_HEAD
    # vc is the C source the bootstrap compiles into `v`, and it is a SEPARATE
    # repository that V's own build clones at HEAD -- UNPINNED. A vc snapshot
    # from a newer V can reject the pinned tree's own vlib, so vc is cloned at
    # its own pin -- the same reasoning CI records in ci.yml.
    git clone -q https://github.com/vlang/vc vc
    git -C vc fetch -q --depth 1 origin $VCCommit
    git -C vc checkout -q FETCH_HEAD
    & cmd /c "makev.bat -gcc --local"
    if (-not (Test-Path (Join-Path $VDir 'v.exe'))) {
        throw "V build finished but produced no v.exe"
    }
    Set-Content -Path $marker -Value $VCommit -NoNewline
    Set-Location $BlipDir
}

Install-PinnedV

& (Join-Path $VDir 'v.exe') -cc gcc -o (Join-Path $BlipDir 'blip.exe') blip.v

Write-Host "==> blip installed to $BlipDir\blip.exe"
Write-Host "==> Add it to your PATH:  `$env:PATH = `"$BlipDir;`$env:PATH`""
Write-Host "==> Try it:               blip repl"
