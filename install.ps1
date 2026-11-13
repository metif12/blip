$ErrorActionPreference = 'Stop'

# blip builds against stock V 0.5.2: the official release archive, not a
# master build. A master build reports the same "V 0.5.2" version string for
# different commits while resolving project modules differently, so "whatever
# vlang/v master is this morning" is how an install works on Friday and fails
# on Monday. The release archive is that compiler, byte for byte, on every
# machine -- no source build, no vc bootstrap.
#
# Keep the version below in sync with .github/workflows/ci.yml.
$VVersion = '0.5.2'

$BlipDir = if ($env:BLIP_INSTALL_DIR) { $env:BLIP_INSTALL_DIR } else { "$HOME\.blip" }
$VDir    = if ($env:BLIP_V_DIR)       { $env:BLIP_V_DIR }       else { "$HOME\.blip-v" }
$Repo    = 'https://github.com/metif12/blip.git'

Write-Host "==> Installing blip to $BlipDir"

if (-not (Test-Path $BlipDir)) {
    git clone $Repo $BlipDir
}

Set-Location $BlipDir
git pull --ff-only

# V compiles every program with a C compiler. Saying so up front beats a bare
# link failure minutes in. The easiest on Windows:
#   scoop install gcc
# or install TDM-GCC / w64devkit and put it on PATH.
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

function Install-StockV {
    # Already downloaded, and downloaded at THIS version? Cheap check via a
    # marker file: `v version` prints a version string, not a build, and is
    # no identity across master builds.
    $marker = Join-Path $VDir '.blip-version'
    if ((Test-Path (Join-Path $VDir 'v.exe')) -and (Test-Path $marker) `
            -and ((Get-Content $marker -Raw).Trim() -eq $VVersion)) {
        return
    }
    Write-Host "==> V $VVersion not found. Downloading the official release..."
    if (Test-Path $VDir) { Remove-Item -Recurse -Force $VDir }
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) 'v_windows.zip'
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'blip-v-dl'
    Invoke-WebRequest -Uri "https://github.com/vlang/v/releases/download/$VVersion/v_windows.zip" -OutFile $zip
    # The archive keeps the toolchain layout (v.exe plus the vlib beside
    # it); extracting only the executable leaves V unable to find vlib.
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    Move-Item (Join-Path $tmp 'v') $VDir
    Remove-Item -Recurse -Force $tmp, $zip
    if (-not (Test-Path (Join-Path $VDir 'v.exe'))) {
        throw "V download finished but produced no v.exe"
    }
    Set-Content -Path $marker -Value $VVersion -NoNewline
}

Install-StockV

# From the repo root, so the relative `vlib` in -path resolves: it points the
# compiler at this repo's own vlib/ for `import blip.*`, with the standard
# library behind it.
& (Join-Path $VDir 'v.exe') -cc gcc -path "vlib|@vlib" -o (Join-Path $BlipDir 'blip.exe') main.v

Write-Host "==> blip installed to $BlipDir\blip.exe"
Write-Host "==> Add it to your PATH:  `$env:PATH = `"$BlipDir;`$env:PATH`""
Write-Host "==> Try it:               blip repl"
