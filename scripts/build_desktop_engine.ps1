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
$BuildDir = Join-Path $RootDir "build_desktop\build"
$BinDir = Join-Path $RootDir "bin"
$UpstreamSrc = Join-Path $RootDir "build_desktop\llama_cpp_upstream"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Building PrivateLM-Mesh Desktop Engine (Windows x64)     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

if (-not (Test-Path (Join-Path $UpstreamSrc "CMakeLists.txt"))) {
    Write-Host "[+] Fetching full upstream llama.cpp..." -ForegroundColor Cyan
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git $UpstreamSrc
}
$LlamaSrc = $UpstreamSrc

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

Write-Host "--> Building Targets llama-server and ggml-rpc-server..." -ForegroundColor Gray
cmake --build $BuildDir --config $BuildType --target llama-server ggml-rpc-server -j $env:NUMBER_OF_PROCESSORS

# Copy output binaries and DLLs to bin/
$ServerCandidates = @(
    (Join-Path $BuildDir "bin\$BuildType\llama-server.exe"),
    (Join-Path $BuildDir "bin\llama-server.exe")
)
foreach ($Cand in $ServerCandidates) {
    if (Test-Path $Cand) {
        Copy-Item $Cand -Destination (Join-Path $BinDir "llama-server.exe") -Force
        break
    }
}

$Candidates = @(
    (Join-Path $BuildDir "bin\$BuildType\ggml-rpc-server.exe"),
    (Join-Path $BuildDir "bin\ggml-rpc-server.exe"),
    (Join-Path $BuildDir "bin\$BuildType\rpc-server.exe"),
    (Join-Path $BuildDir "bin\rpc-server.exe")
)

$FoundExe = $null
foreach ($Candidate in $Candidates) {
    if (Test-Path $Candidate) {
        $FoundExe = $Candidate
        break
    }
}

if ($FoundExe) {
    Copy-Item $FoundExe -Destination (Join-Path $BinDir "rpc-server.exe") -Force
    Copy-Item $FoundExe -Destination (Join-Path $BinDir "ggml-rpc-server.exe") -Force
    
    # Copy supporting runtime DLLs
    $DllDirs = @(
        (Split-Path -Parent $FoundExe),
        (Join-Path $BuildDir "bin\$BuildType"),
        (Join-Path $BuildDir "bin")
    )
    foreach ($d in $DllDirs) {
        if (Test-Path $d) {
            $Dlls = Get-ChildItem -Path $d -Filter "*.dll"
            foreach ($Dll in $Dlls) {
                Copy-Item $Dll.FullName -Destination $BinDir -Force
            }
        }
    }
    
    Write-Host "[✓] Successfully built and installed: $BinDir\llama-server.exe and rpc-server.exe (with runtime DLLs)" -ForegroundColor Green
} else {
    Write-Warning "RPC server binary not found at standard build output paths. Check $($BuildDir)\bin"
}


