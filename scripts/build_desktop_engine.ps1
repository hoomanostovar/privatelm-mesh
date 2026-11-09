# Build script for Windows Desktop (llama.cpp + ggml-rpc-server)
# Usage: .\scripts\build_desktop_engine.ps1 [-Cuda] [-Vulkan]

param (
    [switch]$Cuda = $false,
    [switch]$Vulkan = $false,
    [string]$BuildType = "Release"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$LlamaSrc = Join-Path $RootDir "local_plugins\llama_flutter_android\android\src\main\cpp\llama.cpp"
$BuildDir = Join-Path $RootDir "build_desktop"
$BinDir = Join-Path $RootDir "bin"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Building PrivateLM-Mesh Desktop Engine (Windows x64)     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if (-not (Test-Path $LlamaSrc)) {
    Write-Error "llama.cpp source directory not found at $LlamaSrc"
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

$CmakeArgs = @(
    "-S", $LlamaSrc,
    "-B", $BuildDir,
    "-DCMAKE_BUILD_TYPE=$BuildType",
    "-DGGML_RPC=ON",
    "-DGGML_BUILD_EXAMPLES=OFF",
    "-DGGML_BUILD_TESTS=OFF",
    "-DLLAMA_BUILD_EXAMPLES=ON",
    "-DLLAMA_BUILD_SERVER=ON"
)

if ($Cuda) {
    Write-Host "[+] Enabling NVIDIA CUDA Acceleration..." -ForegroundColor Green
    $CmakeArgs += "-DGGML_CUDA=ON"
} elseif ($Vulkan) {
    Write-Host "[+] Enabling Khronos Vulkan GPU Acceleration..." -ForegroundColor Green
    $CmakeArgs += "-DGGML_VULKAN=ON"
} else {
    Write-Host "[+] Building CPU backend (AVX2/AVX-512 vectorization)..." -ForegroundColor Yellow
}

Write-Host "--> Running CMake Configuration..." -ForegroundColor Gray
cmake @CmakeArgs

Write-Host "--> Building Targets (rpc-server, llama, ggml)..." -ForegroundColor Gray
cmake --build $BuildDir --config $BuildType --target rpc-server -j $env:NUMBER_OF_PROCESSORS

# Copy output binaries to bin/
$OutExe = Join-Path $BuildDir "bin\$BuildType\rpc-server.exe"
if (-not (Test-Path $OutExe)) {
    $OutExe = Join-Path $BuildDir "bin\rpc-server.exe"
}

if (Test-Path $OutExe) {
    Copy-Item $OutExe -Destination (Join-Path $BinDir "rpc-server.exe") -Force
    Write-Host "[✓] Successfully built: $BinDir\rpc-server.exe" -ForegroundColor Green
} else {
    Write-Warning "rpc-server.exe not found at standard build output path. Check $BuildDir\bin"
}
