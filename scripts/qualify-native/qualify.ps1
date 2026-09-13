# scripts/qualify-native/qualify.ps1 - thin public entry for native qualification.
# Locates Python 3, forces bytecode-off, and invokes qualify.py. All inspection,
# ESP binding, Docker/QEMU TCG launch and evidence writing happen in Python.
# There is no host QEMU/OVMF path and no hosted-binary fallback.
#
# Usage (normally via `zig build qualify-native`):
#   qualify.ps1 -EspImage <esp.img> -Loader <BOOTX64.efi> -Kernel <zk-kernel> `
#               -Initramfs <initramfs.bin> -ImgInfo <imginfo.exe>

param(
    [Parameter(Mandatory = $true)][string]$EspImage,
    [Parameter(Mandatory = $true)][string]$Loader,
    [Parameter(Mandatory = $true)][string]$Kernel,
    [Parameter(Mandatory = $true)][string]$Initramfs,
    [Parameter(Mandatory = $true)][string]$ImgInfo,
    [string]$Python = "",
    [string]$QemuImage = "zig-kernel-qemu-verifier:local",
    [string]$QemuImageId = "sha256:8385adfe772b198700e89273eb4d4243f89ee6c1e3367bf2661f1a0d33c9e458",
    [string]$QemuAccel = "tcg",
    [int]$TimeoutSec = 45,
    [string]$EvidenceDir = "",
    [string]$DockerHost = "",
    [string]$DockerConfig = "",
    [string]$InitramfsPath = "/ZK/INITRD.BIN"
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$qualifyPy = Join-Path $here "qualify.py"

function Get-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Test-AllowedOutputPath([string]$Path) {
    $full = Get-FullPath $Path
    if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        return $full.StartsWith("D:", [System.StringComparison]::OrdinalIgnoreCase)
    }
    return [System.IO.Path]::IsPathRooted($full)
}

function Write-Unavailable([string]$Reason, [string]$Parent) {
    $payload = [ordered]@{
        status                        = "unavailable"
        verdict                       = "unavailable"
        reason                        = $Reason
        linux_replacement_qualified   = $false
        errors                        = @($Reason)
        kernel_entry_observed         = $false
        launched                      = $false
    }
    Write-Host "qualify-native: unavailable - $Reason"
    if ($Parent -and (Test-AllowedOutputPath $Parent)) {
        $fullParent = Get-FullPath $Parent
        $stamp = Get-Date -Format "yyyyMMddTHHmmss"
        $dir = Join-Path $fullParent ("native-qualify-" + $stamp + "-ps")
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $path = Join-Path $dir "evidence.json"
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 4), $utf8)
        Write-Host "qualify-native: evidence at $path"
    }
    exit 2
}

function Resolve-Python3([string]$Hint) {
    if ($Hint) {
        if (-not (Test-Path -LiteralPath $Hint)) { return $null }
        try {
            & $Hint -c "import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)"
            if ($LASTEXITCODE -eq 0) { return $Hint }
        } catch {
        }
        return $null
    }
    $candidates = @()
    if ($env:QUALIFY_PYTHON) { $candidates += $env:QUALIFY_PYTHON }
    foreach ($name in @("python3", "python")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $candidates += $cmd.Source }
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $launched = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($launched) { $candidates += $launched.Trim() }
        } catch {
        }
    }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try {
            & $c -c "import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)"
            if ($LASTEXITCODE -eq 0) { return $c }
        } catch {
        }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $qualifyPy)) {
    Write-Unavailable "qualify.py missing at $qualifyPy" $EvidenceDir
}

$pythonExe = Resolve-Python3 $Python
if (-not $pythonExe) {
    Write-Unavailable "Python 3 is required and was not found" $EvidenceDir
}

if (-not $EvidenceDir) {
    $EvidenceDir = Join-Path (Get-Location).Path "qualify-native-evidence"
}
if (-not (Test-AllowedOutputPath $EvidenceDir)) {
    Write-Unavailable ("output must be on D:, got " + (Get-FullPath $EvidenceDir)) ""
}
$EvidenceDir = Get-FullPath $EvidenceDir
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

$scratch = Join-Path $EvidenceDir "scratch"
if (-not (Test-AllowedOutputPath $scratch)) {
    Write-Unavailable ("output must be on D:, got " + (Get-FullPath $scratch)) ""
}
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$env:TMP = $scratch
$env:TEMP = $scratch
$env:TMPDIR = $scratch
$env:PYTHONDONTWRITEBYTECODE = "1"
$env:PYTHONNOUSERSITE = "1"

$pyArgs = @(
    "-B", $qualifyPy,
    "--esp-image", $EspImage,
    "--loader", $Loader,
    "--kernel", $Kernel,
    "--initramfs", $Initramfs,
    "--imginfo", $ImgInfo,
    "--initramfs-path", $InitramfsPath,
    "--qemu-image", $QemuImage,
    "--qemu-image-id", $QemuImageId,
    "--qemu-accel", $QemuAccel,
    "--timeout", "$TimeoutSec",
    "--evidence-parent", $EvidenceDir
)
if ($DockerHost) {
    $pyArgs += @("--docker-host", $DockerHost)
}
if ($DockerConfig) {
    $pyArgs += @("--docker-config", $DockerConfig)
}

& $pythonExe @pyArgs
exit $LASTEXITCODE
