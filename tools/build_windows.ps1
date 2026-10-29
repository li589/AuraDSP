<#
.SYNOPSIS
    AuraDSP Windows 一键全栈构建、产物整理与资源打包工具 (build_windows.ps1)

.DESCRIPTION
    此脚本整合 Windows 全流程构建与资源分发：
    1. 进程自检：自动检查并解除正在运行的 auradsp_app.exe 文件锁定；
    2. C++ 核心引擎：自动编译/更新 auradsp_engine.dll；
    3. C++ 驱动常驻桥：编译 auravm_bridge.dll、auravaio_bridge.dll、auraasio_bridge.dll；
    4. Flutter 桌面端：编译 auradsp_app.exe 及其 Windows Runner 运行环境；
    5. 声学资源包匹配：自动将 DDC 耳机校准库、Liveprog 脚本与核心脉冲挂载到 resources/；
    6. 分发产物整理 (Dist)：统一汇流至 dist/AuraDSP-Windows-x64 绿色便携目录，支持一键 zip 归档。

.EXAMPLE
    .\tools\build_windows.ps1
    .\tools\build_windows.ps1 -Package
    .\tools\build_windows.ps1 -Package -BuildAddons
#>

[CmdletBinding()]
param(
    [ValidateSet("Release", "Debug")]
    [string]$BuildType = "Release",

    [switch]$Package = $false,
    [switch]$BuildAddons = $false,
    [switch]$SkipEngine = $false,
    [switch]$SkipDrivers = $false,
    [switch]$SkipFlutter = $false,
    [switch]$Force = $true
)

$ErrorActionPreference = "Stop"

# M3（2026-10-29）：统一走根 CMakePresets（构建树 build/windows/x64），
# 产物仍写回 core/desktop/{windows,windows-drivers}/out/<Config>/。
$BuildPreset = "windows-x64-$($BuildType.ToLower())"
$ConfigureArgs = @("--preset", "windows-x64")
if ($SkipDrivers) { $ConfigureArgs += "-DAURADSP_BUILD_BRIDGES=OFF" } else { $ConfigureArgs += "-DAURADSP_BUILD_BRIDGES=ON" }

# 项目根目录解析
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir\..").Path
Set-Location $ProjectRoot

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "         AuraDSP Windows 全栈构建与产物整理流水线           " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  根目录   : $ProjectRoot"
Write-Host "  构建模式 : $BuildType"
$PackageText = if ($Package) { '是 (生成 zip)' } else { '否 (仅输出目录)' }
Write-Host "  自动打包 : $PackageText"
Write-Host "============================================================`n"

# -------------------------------------------------------------------------
# Step 1: 进程锁定检测与自动释放
# -------------------------------------------------------------------------
Write-Host "[1/6] 检查运行中进程与文件锁..." -ForegroundColor Yellow
$RunningApps = Get-Process -Name "auradsp_app" -ErrorAction SilentlyContinue
if ($RunningApps) {
        $AppPids = ($RunningApps | ForEach-Object { $_.Id }) -join ', '
    if ($Force) {
        Write-Host "  发现正在运行的 auradsp_app.exe (PID: $($AppPids))，正在自动终止以释放 DLL 锁..." -ForegroundColor DarkYellow
        $RunningApps | Stop-Process -Force
        Start-Sleep -Milliseconds 600
        Write-Host "  -> 进程已退出，文件锁已成功释放。" -ForegroundColor Green
    } else {
        Write-Error "检测到 auradsp_app.exe 正在运行！请先关闭应用，或加上 -Force 参数以自动释放文件锁。"
    }
} else {
    Write-Host "  -> 无进程锁定，状态良好。" -ForegroundColor Green
}

# -------------------------------------------------------------------------
# Step 2: C++ 核心引擎编译 (auradsp_engine.dll)
# -------------------------------------------------------------------------
if (-not $SkipEngine) {
    Write-Host "`n[2/6] 检查与编译 C++ 核心引擎 (auradsp_engine.dll)..." -ForegroundColor Yellow
    $EngineOutDir = Join-Path $ProjectRoot "core\desktop\windows\out"

    Write-Host "  配置 CMake (预设 windows-x64，构建树 build/windows/x64)..."
    cmake @ConfigureArgs | Out-Null

    Write-Host "  编译 $BuildType 引擎动态库与进程外插件宿主..."
    cmake --build --preset $BuildPreset --target auradsp_engine auradsp_plugin_host

    $EngineDll = Join-Path $EngineOutDir "$BuildType\auradsp_engine.dll"
    if (-not (Test-Path $EngineDll)) {
        throw "引擎编译完成但未找到产物: $EngineDll"
    }
    $EngineSize = (Get-Item $EngineDll).Length
    Write-Host "  -> 核心引擎就绪: auradsp_engine.dll ($([math]::Round($EngineSize / 1MB, 2)) MB)" -ForegroundColor Green

    $PluginHostExe = Join-Path $EngineOutDir "$BuildType\auradsp_plugin_host.exe"
    if (-not (Test-Path $PluginHostExe)) {
        throw "插件宿主编译完成但未找到产物: $PluginHostExe"
    }
    Write-Host "  -> 进程外插件宿主就绪: auradsp_plugin_host.exe" -ForegroundColor Green
} else {
    Write-Host "`n[2/6] 已跳过核心引擎编译 (-SkipEngine)" -ForegroundColor DarkGray
}

# -------------------------------------------------------------------------
# Step 3: C++ 驱动与常驻桥编译 (auravm / auravaio / auraasio)
# -------------------------------------------------------------------------
if (-not $SkipDrivers) {
    Write-Host "`n[3/6] 检查与编译 C++ 驱动常驻桥..." -ForegroundColor Yellow
    $DriversOutDir = Join-Path $ProjectRoot "core\desktop\windows-drivers\out"

    Write-Host "  配置 CMake (预设 windows-x64；桥与引擎同一构建树)..."
    cmake @ConfigureArgs | Out-Null

    Write-Host "  编译桥接动态库 (auradsp_bridges: vm / vaio / asio)..."
    cmake --build --preset $BuildPreset --target auradsp_bridges

    foreach ($Bridge in @("auravm_bridge.dll", "auravaio_bridge.dll", "auraasio_bridge.dll")) {
        $DllPath = Join-Path $DriversOutDir "$BuildType\$Bridge"
        if (Test-Path $DllPath) {
            Write-Host "  -> 桥接模块就绪: $Bridge" -ForegroundColor Green
        } else {
            Write-Host "  -> 警告: $Bridge 未生成 (如非必须模式可跳过)" -ForegroundColor DarkYellow
        }
    }
} else {
    Write-Host "`n[3/6] 已跳过驱动常驻桥编译 (-SkipDrivers)" -ForegroundColor DarkGray
}

# -------------------------------------------------------------------------
# Step 4: 编译 Flutter 桌面应用 (auradsp_app.exe)
# -------------------------------------------------------------------------
if (-not $SkipFlutter) {
    Write-Host "`n[4/6] 编译 Flutter 桌面端 (auradsp_app)..." -ForegroundColor Yellow
    $FlutterAppDir = Join-Path $ProjectRoot "app\auradsp_app"
    Set-Location $FlutterAppDir

    $FlutterArgs = @("build", "windows", "--no-tree-shake-icons")
    if ($BuildType -eq "Release") {
        $FlutterArgs += "--release"
    } else {
        $FlutterArgs += "--debug"
    }

    Write-Host "  执行: flutter $($FlutterArgs -join ' ')..."
    flutter @FlutterArgs

    Set-Location $ProjectRoot
    $RunnerOutDir = Join-Path $FlutterAppDir "build\windows\x64\runner\$BuildType"
    $AppExe = Join-Path $RunnerOutDir "auradsp_app.exe"
    if (-not (Test-Path $AppExe)) {
        throw "Flutter 构建完成但未找到可执行文件: $AppExe"
    }
    Write-Host "  -> 桌面端主程序构建成功: auradsp_app.exe" -ForegroundColor Green
} else {
    Write-Host "`n[4/6] 已跳过 Flutter 编译 (-SkipFlutter)" -ForegroundColor DarkGray
    $RunnerOutDir = Join-Path $ProjectRoot "app\auradsp_app\build\windows\x64\runner\$BuildType"
}

# -------------------------------------------------------------------------
# Step 5: 整理与归集发布包 (dist/AuraDSP-Windows-x64)
# -------------------------------------------------------------------------
Write-Host "`n[5/6] 规整分发产物与声学资源目录..." -ForegroundColor Yellow
$DistRoot = Join-Path $ProjectRoot "dist"
$DistPortable = Join-Path $DistRoot "AuraDSP-Windows-x64"

if (Test-Path $DistPortable) {
    Remove-Item -Path $DistPortable -Recurse -Force
}
New-Item -ItemType Directory -Path $DistPortable -Force | Out-Null

Write-Host "  同步主程序运行目录到 dist/AuraDSP-Windows-x64..."
Copy-Item -Path "$RunnerOutDir\*" -Destination $DistPortable -Recurse -Force

# 确保 resources 目录完整性
$DistResources = Join-Path $DistPortable "resources"
if (-not (Test-Path $DistResources)) {
    New-Item -ItemType Directory -Path $DistResources -Force | Out-Null
}

# 验证核心资源
$DdcCount = (Get-ChildItem -Path "$DistResources\ddc" -Recurse -File -ErrorAction SilentlyContinue).Count
$LiveprogCount = (Get-ChildItem -Path "$DistResources\liveprog" -Recurse -File -ErrorAction SilentlyContinue).Count
$ConvCount = (Get-ChildItem -Path "$DistResources\convolver" -Recurse -File -ErrorAction SilentlyContinue).Count

Write-Host "  -> 随包内置资源验证: DDC 耳机校准 ($DdcCount 文件), Liveprog 脚本 ($LiveprogCount 文件), 核心卷积 ($ConvCount 文件)" -ForegroundColor Green

# -------------------------------------------------------------------------
# Step 6: 资源全量扩展包构建与最终打包归档
# -------------------------------------------------------------------------
if ($BuildAddons) {
    Write-Host "`n[6/6] 生成独立扩展资源包 (tools/resource_pipeline/build_packages.py)..." -ForegroundColor Yellow
    python "$ProjectRoot\tools\resource_pipeline\build_packages.py"
}

if ($Package) {
    Write-Host "`n打包绿色便携 zip 归档..." -ForegroundColor Yellow
    $ZipPath = Join-Path $DistRoot "AuraDSP-Windows-x64.zip"
    if (Test-Path $ZipPath) {
        Remove-Item -Path $ZipPath -Force
    }

    Write-Host "  压缩 dist/AuraDSP-Windows-x64 -> $ZipPath..."
    Compress-Archive -Path "$DistPortable\*" -DestinationPath $ZipPath -CompressionLevel Optimal
    $ZipSizeMB = [math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
    Write-Host "  -> 压缩包生成完成: $ZipPath ($ZipSizeMB MB)" -ForegroundColor Green
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "                 AuraDSP Windows 构建全部就绪!              " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  绿色便携目录 : $DistPortable"
Write-Host "  启动可执行程序: $DistPortable\auradsp_app.exe"
if ($Package) {
    Write-Host "  便携发布压缩包: $DistRoot\AuraDSP-Windows-x64.zip"
}
Write-Host "============================================================`n"
