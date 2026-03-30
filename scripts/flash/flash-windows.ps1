# =============================================================================
# flash-windows.ps1
#
# ⚠️  IMPORTANT — READ BEFORE USING  ⚠️
#
# This script copies the EVL kernel Image, DTBs, and extlinux.conf to the
# FAT32 boot partition of an SD card that is already mounted by Windows.
#
# THIS IS MODE B (INJECT ONLY) — it requires that the SD card ALREADY contains
# a working SpacemiT/buildroot OS with U-Boot SPL at the correct raw sector
# offset.  If the SD card is blank or was never flashed with a full Jupiter
# image, this script WILL NOT make it bootable.
#
# ─────────────────────────────────────────────────────────────────────────────
# RECOMMENDED WORKFLOW (first-time or clean flash):
# ─────────────────────────────────────────────────────────────────────────────
# 1. In WSL2, build the complete EVL SD card image:
#      bash scripts/flash/make-full-sdcard-img.sh \
#          ~/Downloads/buildroot-k1_rt-sdcard.img \
#          ~/work/build-k1 \
#          /mnt/c/Users/<you>/Downloads
#
# 2. In Windows, flash the resulting evl-sdcard-k1-*.img to the SD card using:
#    • Balena Etcher  — https://etcher.balena.io/  (recommended, free)
#    • Rufus          — select "DD image" mode, NOT "ISO mode"
#    • Win32DiskImager
#    Write to the WHOLE SD card disk (e.g. Disk 2), NOT a partition.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHEN TO USE THIS SCRIPT (subsequent kernel updates only):
# ─────────────────────────────────────────────────────────────────────────────
# After the SD card is already running a Jupiter OS, use this script to
# replace only the kernel/DTBs/extlinux.conf without re-flashing the whole disk:
#
#   .\scripts\flash\flash-windows.ps1 -BootDrive D:
#
# Parameters:
#   -BootDrive   Drive letter of the SD card FAT32 boot partition (e.g. D:)
#   -BuildDir    WSL2 kernel build output dir (default: auto-detected)
#   -RepoDir     WSL2 repo root dir (default: auto-detected)
#   -WslDistro   WSL2 distro name (default: Ubuntu)
# =============================================================================
param(
    [Parameter(Mandatory=$true)]
    [string]$BootDrive,

    [string]$BuildDir = "",
    [string]$RepoDir  = "",
    [string]$WslDistro = "Ubuntu"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Info  { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Ok    { param($msg) Write-Host "[ OK ]  $msg" -ForegroundColor Green }
function Warn  { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Die   { param($msg) Write-Host "[FAIL]  $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Resolve WSL2 paths
# ---------------------------------------------------------------------------
$WslRoot = "\\wsl$\$WslDistro"

if ($BuildDir -eq "") {
    $BuildDir = "$WslRoot\home\$env:USERNAME\work\build-k1"
    # Fallback: try common WSL username
    if (-not (Test-Path $BuildDir)) {
        $WslUsers = Get-ChildItem "$WslRoot\home" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($WslUsers) {
            $BuildDir = "$WslRoot\home\$($WslUsers.Name)\work\build-k1"
        }
    }
}

if ($RepoDir -eq "") {
    $RepoDir = "$WslRoot\home\$env:USERNAME\projects\spacemit-xenomai"
    if (-not (Test-Path $RepoDir)) {
        $WslUsers = Get-ChildItem "$WslRoot\home" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($WslUsers) {
            $RepoDir = "$WslRoot\home\$($WslUsers.Name)\projects\spacemit-xenomai"
        }
    }
}

# Normalize boot drive path
$BootPath = $BootDrive.TrimEnd('\') + '\'

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
Info "Build dir : $BuildDir"
Info "Repo dir  : $RepoDir"
Info "Boot drive: $BootPath"

if (-not (Test-Path $BuildDir)) {
    Die "Build directory not found: $BuildDir`nMake sure WSL2 is running and the kernel has been built."
}

$KernelImage = "$BuildDir\arch\riscv\boot\Image"
$DtbDir      = "$BuildDir\arch\riscv\boot\dts\spacemit"
$ExtlinuxSrc = "$RepoDir\configs\extlinux.conf"

if (-not (Test-Path $KernelImage)) { Die "Kernel image not found: $KernelImage" }
if (-not (Test-Path $DtbDir))      { Die "DTB directory not found: $DtbDir" }
if (-not (Test-Path $BootPath))    { Die "Boot drive not found: $BootPath — is the SD card inserted?" }

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------
Write-Host ""
Warn "=========================================================="
Warn "  ABOUT TO WRITE TO: $BootPath"
Warn "  Kernel : $KernelImage"
Warn "  DTBs   : $DtbDir"
Warn "  This will OVERWRITE files on the boot partition!"
Warn "=========================================================="
Write-Host ""
$confirm = Read-Host "Type 'yes' to continue, anything else to abort"
if ($confirm -ne "yes") { Info "Aborted."; exit 0 }

# ---------------------------------------------------------------------------
# Copy kernel image
# ---------------------------------------------------------------------------
Info "Copying kernel Image ..."
Copy-Item $KernelImage "$BootPath\Image" -Force
Ok "Kernel copied."

# ---------------------------------------------------------------------------
# Copy DTBs
# ---------------------------------------------------------------------------
Info "Copying DTBs ..."
$DtbDest = "$BootPath\dtbs\spacemit"
New-Item -ItemType Directory -Force $DtbDest | Out-Null
$dtbs = Get-ChildItem "$DtbDir\*.dtb" -ErrorAction SilentlyContinue
if ($dtbs.Count -eq 0) {
    Warn "No DTBs found in $DtbDir — skipping."
} else {
    Copy-Item "$DtbDir\*.dtb" $DtbDest -Force
    Ok "$($dtbs.Count) DTBs copied."
}

# ---------------------------------------------------------------------------
# Copy extlinux.conf
# ---------------------------------------------------------------------------
if (Test-Path $ExtlinuxSrc) {
    Info "Copying extlinux.conf ..."
    $ExtlinuxDest = "$BootPath\extlinux"
    New-Item -ItemType Directory -Force $ExtlinuxDest | Out-Null
    Copy-Item $ExtlinuxSrc "$ExtlinuxDest\extlinux.conf" -Force
    Ok "extlinux.conf copied."
} else {
    Warn "extlinux.conf not found at $ExtlinuxSrc — skipping."
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  SD card ready!" -ForegroundColor Green
Write-Host "  Insert into Milk-V Jupiter and power on." -ForegroundColor Green
Write-Host "  See docs/testing.md for boot verification steps." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
