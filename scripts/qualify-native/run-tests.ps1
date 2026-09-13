# scripts/qualify-native/run-tests.ps1 - host regression suite for the qualifier.
param(
    [string]$Python = "",
    [string]$ScratchDir = ""
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$worktree = (Resolve-Path (Join-Path $here "../..")).Path

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

$pythonExe = Resolve-Python3 $Python
if (-not $pythonExe) {
    Write-Error "Python 3 is required to run native qualification tests"
    exit 2
}

if (-not $ScratchDir) {
    $ScratchDir = Join-Path $worktree "qualify-native-test-scratch"
}
$ScratchDir = Get-FullPath $ScratchDir
if (-not (Test-AllowedOutputPath $ScratchDir)) {
    Write-Error "scratch must be on D:, got $ScratchDir"
    exit 2
}
New-Item -ItemType Directory -Force -Path $ScratchDir | Out-Null
$env:TMP = $ScratchDir
$env:TEMP = $ScratchDir
$env:TMPDIR = $ScratchDir
$env:PYTHONDONTWRITEBYTECODE = "1"
$env:PYTHONNOUSERSITE = "1"
$env:QUALIFY_TEST_SCRATCH = $ScratchDir

Set-Location $worktree
& $pythonExe -B (Join-Path $here "run-tests.py")
exit $LASTEXITCODE
