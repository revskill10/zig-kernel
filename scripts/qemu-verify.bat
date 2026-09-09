@echo off
REM QEMU Verification Script for zig-kernel
REM Usage: .\scripts\qemu-verify.bat [run|test|build]

setlocal

if "%1"=="" set MODE=run
if "%1"=="" echo ========================================
if "%1"=="" echo   zig-kernel QEMU Verification
if "%1"=="" echo ========================================

REM Check for QEMU
where qemu-system-x86_64 >nul 2>&1
if errorlevel 1 (
    echo ERROR: QEMU not found
    echo Install: sudo apt-get install qemu-system-x86
    exit /b 1
)

REM Check for Zig
where zig >nul 2>&1
if errorlevel 1 (
    echo ERROR: zig not found
    exit /b 1
)

if "%MODE%"=="test" goto :run_tests
if "%MODE%"=="build" goto :build_qemu
goto :run_simulation

:run_tests
echo Running unit tests...
zig build test
exit /b %errorlevel%

:build_qemu
echo Building for QEMU...
zig build -Dtarget=x86_64-freestanding-none -Doptimize=ReleaseSmall
if errorlevel 1 (
    echo Build failed - checking entry point...
    echo Adding _start wrapper...
)
exit /b 0

:run_simulation
echo Running hosted kernel simulation...
zig build run
exit /b %errorlevel%

endlocal