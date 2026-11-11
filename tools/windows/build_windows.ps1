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
    6. 分发产物整理 (Dist)：统一汇流至 dist/AuraDSP-Windows-x64 绿色便携目录，
       写入 build-info.txt（版本 / 提交 / SHA256 清单），支持一键 zip 归档。

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
    [switch]$SkipHostX86 = $false,
    [switch]$Force = $true
)

$ErrorActionPreference = "Stop"

# M3（2026-10-29）：统一走根 CMakePresets（构建树 build/windows/x64），
# 产物仍写回 core/desktop/{windows,windows-drivers}/out/<Config>/。
$BuildPreset = "windows-x64-$($BuildType.ToLower())"
$ConfigureArgs = @("--preset", "windows-x64")
if ($SkipDrivers) { $ConfigureArgs += "-DAURADSP_BUILD_BRIDGES=OFF" } else { $ConfigureArgs += "-DAURADSP_BUILD_BRIDGES=ON" }

# 项目根目录解析（M5：脚本位于 tools/windows/，仓库根为两级父目录）
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir\..\..").Path
Set-Location $ProjectRoot

# 本次构建起点：用于判定产物是不是"这次编出来的"。
# 编译失败时 cmake 会留下旧产物，只看文件存在就会误报就绪（见下方 freshness 校验）。
$BuildStartedAt = Get-Date

# 最新源文件时间：产物必须比它新才算"与当前源码同步"。
# 不用 BuildStartedAt 做基准——目标本就最新时 cmake 不会重编，产物时间戳
# 天然早于构建起点，那样会误报"陈旧"。
$SourceRoots = @((Join-Path $ProjectRoot "engine"), (Join-Path $ProjectRoot "core")) |
Where-Object { Test-Path $_ }
$SourceNewest = (Get-ChildItem -Path $SourceRoots -Include *.c, *.cpp, *.h, *.hpp, *.cc `
        -Recurse -File -ErrorAction SilentlyContinue |
    Measure-Object -Property LastWriteTime -Maximum).Maximum
if (-not $SourceNewest) { $SourceNewest = [datetime]::MinValue }

# -------------------------------------------------------------------------
# 环境归一化（2026-11-09）
# -------------------------------------------------------------------------
# 某些宿主环境（CI 包装器 / 沙箱代理 / 多层进程继承）会让原生环境块里出现
# `PATH` / `path` / `Path` 等大小写重复键，甚至每个变量都出现两份。
# Windows 查找变量本身大小写不敏感，但 **.NET Framework** 的
# `ProcessStartInfo.EnvironmentVariables` 内部是大小写敏感的 Hashtable，
# 把原生块灌进去时第二个 "path" 撞键抛 ArgumentException('path')。
#
# 这条异常发生在 MSBuild 的 ToolTask.GetProcessStartInfo 里，于是
# **CL.exe 根本没被拉起**：编译目标既不产出、也不让上层脚本失败，
# 最坏情况是脚本只检查"文件存在"就宣布就绪 —— 静默产出陈旧二进制。
# 本仓库实踩过：引擎 DLL 时间戳停在两天前，构建脚本却打印"核心引擎就绪"。
#
# 修法：所有外部命令经 tools/bin/win_env_sanitize.py 归一化环境后再启动。
# PATH 取所有变体的并集，其余变量保留首次出现的值。
$EnvSanitizer = Join-Path $ProjectRoot "tools\bin\win_env_sanitize.py"

# MSBuild 并行度上限。VS 生成器默认按逻辑核数并行（32 核机器上 /m:32），
# C++ 大 TU 同时编译的内存峰值可超过 8GB——机器内存紧张时（旁边还开着
# 虚拟机）进程会被直接杀掉，表现为构建无任何报错地中断、日志为空。
# 限到 8 并发后内存峰值可控，构建时间基本不受影响。
# 用 `-m:8` 而非 `/m:8`：MSBuild 两者等价，但 `/m:8` 从 Git-Bash 调用时会被
# MSYS 的路径转换吃掉斜杠（变成 `m:8`），MSBuild 随即报 MSB1008。
$BuildJobs = 8

# 清理**本仓库构建树**相关的残留 MSBuild/cmake 进程。
# 上一轮构建若被超时/中断杀掉，其 MSBuild 子进程会存活并持有构建树锁；
# 同一轮构建里前一个 MSBuild 目标也可能残留未退出。
# 后果都一样：下一个 MSBuild 目标在同一步骤上"挂起"——无输出、无报错，
# 只能靠超时收场，并留下新的孤儿进程，形成自我延续的死循环。
# 判定依据是命令行里是否引用本仓库路径，不误伤 Visual Studio 等无关进程。
function Stop-StaleBuildProcesses {
    $pattern = [regex]::Escape($ProjectRoot)
    $stale = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @("MSBuild.exe", "cmake.exe", "cl.exe", "link.exe", "mspdbsrv.exe") -and
            $_.CommandLine -and $_.CommandLine -match $pattern
        })
    foreach ($p in $stale) {
        Write-Host ("  -> 清理残留构建进程: {0} (PID {1})" -f $p.Name, $p.ProcessId) -ForegroundColor DarkYellow
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($stale.Count -gt 0) { Start-Sleep -Seconds 2 }
}

function Invoke-Clean {
    param(
        [Parameter(Mandatory = $true)][string[]]$Cmd,
        [string]$Log = "",
        [int]$Retries = 3
    )
    $envArgs = $Cmd
    if ($Log) {
        # 编译日志走原始字节直写：MSBuild 输出含非本地代码页字符，
        # 经 PowerShell 管道会被转码炸掉（UnicodeEncodeError: 'gbk' codec...）。
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Log) | Out-Null
        $envArgs = @("--log", $Log) + $Cmd
    }
    $attempt = 0
    $TraceLog = Join-Path $ProjectRoot "build\reports\build_trace.log"
    while ($true) {
        $attempt++
        Stop-StaleBuildProcesses
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Add-Content -Path $TraceLog -Encoding utf8 -Value (
            "{0}  START  attempt={1}  {2}" -f (Get-Date -Format "HH:mm:ss"), $attempt, ($Cmd -join ' '))
        & python $EnvSanitizer @envArgs
        $rc = $LASTEXITCODE
        Add-Content -Path $TraceLog -Encoding utf8 -Value (
            "{0}  END    attempt={1}  exit={2}  {3:N1}s  {4}" -f (Get-Date -Format "HH:mm:ss"), $attempt, $rc, $sw.Elapsed.TotalSeconds, ($Cmd -join ' '))
        if ($rc -eq 0) { return }
        if ($attempt -ge $Retries) {
            if ($Log -and (Test-Path $Log)) {
                Write-Host "---- 编译日志尾部 ($Log) ----" -ForegroundColor DarkYellow
                Get-Content -Path $Log -Tail 40 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host $_ }
            }
            throw "外部命令失败 (exit=$LASTEXITCODE，重试 $attempt 次): $($Cmd -join ' ')"
        }
        # 间歇性失败（进程被外部终止 / 上一次 MSBuild 节点尚在退出）重试即可过，
        # 单独复跑同一命令总是成功，故重试比直接失败更合适。
        Write-Host ("  -> 外部命令失败 (exit=$LASTEXITCODE)，第 $attempt 次，3 秒后重试: {0}" -f ($Cmd -join ' ')) -ForegroundColor DarkYellow
        Start-Sleep -Seconds 3
    }
}

# 产物存在性校验（硬判据）：编译"成功"却找不到产物，必须中止。
#
# 注意：这里**不能**用"产物时间戳 vs 最新源文件时间"做硬判据——git checkout
# 会把工作树里所有文件的 mtime 刷新成检出时间，于是"没改动的源文件"也会显得
# 比产物新，合法跳过重编的目标（本次的 auraasio_driver）会被误判为陈旧。
# 真正可靠且曾经被漏掉的硬判据是**构建命令的退出码**：MSBuild 因环境变量
# 键重复起不来时会返回 1，而旧脚本只检查文件存在，于是静默产出陈旧二进制。
# 由 Invoke-Clean 的退出码检查兜住，这里只负责"产物必须存在"。
function Assert-Fresh {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = ""
    )
    if (-not (Test-Path $Path)) {
        throw "编译完成但未找到产物: $Path"
    }
    $item = Get-Item $Path
    if ($item.LastWriteTime -lt $SourceNewest) {
        # 提示而非中止：目标本就最新时 cmake 不会重编，产物时间天然偏旧。
        Write-Host ("  -> 提示: {0}时间戳 {1} 早于最新源文件 {2}（若该目标确实无需改动则属正常）" -f `
                $Label, $item.LastWriteTime, $SourceNewest) -ForegroundColor DarkGray
    }
    return $item
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "         AuraDSP Windows 全栈构建与产物整理流水线           " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  根目录   : $ProjectRoot"
Write-Host "  构建模式 : $BuildType"
$PackageText = if ($Package) { '是 (生成 zip)' } else { '否 (仅输出目录)' }
Write-Host "  自动打包 : $PackageText"
Write-Host "============================================================`n" 
Write-Host "`n"
# -------------------------------------------------------------------------
# Step 1: 进程锁定检测与自动释放
# -------------------------------------------------------------------------
Write-Host "[1/6] 检查运行中进程与文件锁..." -ForegroundColor Yellow

# 清理**本仓库构建树**相关的残留 MSBuild/cmake 进程（详见 Stop-StaleBuildProcesses）。
Stop-StaleBuildProcesses

$RunningApps = Get-Process -Name "auradsp_app" -ErrorAction SilentlyContinue
if ($RunningApps) {
    $AppPids = ($RunningApps | ForEach-Object { $_.Id }) -join ', '
    if ($Force) {
        Write-Host "  发现正在运行的 auradsp_app.exe (PID: $($AppPids))，正在自动终止以释放 DLL 锁..." -ForegroundColor DarkYellow
        $RunningApps | Stop-Process -Force
        Start-Sleep -Milliseconds 600
        Write-Host "  -> 进程已退出，文件锁已成功释放。" -ForegroundColor Green
    }
    else {
        Write-Error "检测到 auradsp_app.exe 正在运行！请先关闭应用，或加上 -Force 参数以自动释放文件锁。"
    }
}
else {
    Write-Host "  -> 无进程锁定，状态良好。" -ForegroundColor Green
}

# -------------------------------------------------------------------------
# Step 2: C++ 核心引擎编译 (auradsp_engine.dll)
# -------------------------------------------------------------------------
if (-not $SkipEngine) {
    Write-Host "`n[2/6] 检查与编译 C++ 核心引擎 (auradsp_engine.dll)..." -ForegroundColor Yellow
    $EngineOutDir = Join-Path $ProjectRoot "core\desktop\windows\out"

    Write-Host "  配置 CMake (预设 windows-x64，构建树 build/windows/x64)..."
    Invoke-Clean (@("cmake") + $ConfigureArgs) `
        -Log (Join-Path $ProjectRoot "build\reports\cmake_configure.log") | Out-Null

    # R3（M6 审查遗留）：auradsp_plugin_host target 仅在 AURADSP_PLUGIN_HOST_REMOTE=ON
    # 时存在（Windows 默认 ON；非 Windows / 裁剪配置为 OFF）。从 CMake 缓存读取实际
    # 值决定 target 集合，避免 OFF 时构建因 target 不存在而失败。
    $CMakeCache = Join-Path $ProjectRoot "build\windows\x64\CMakeCache.txt"
    $HostRemote = $true
    if (Test-Path $CMakeCache) {
        $CacheLine = Select-String -Path $CMakeCache -Pattern '^AURADSP_PLUGIN_HOST_REMOTE:BOOL=(ON|OFF)' | Select-Object -First 1
        if ($CacheLine -and $CacheLine.Matches[0].Groups[1].Value -eq 'OFF') { $HostRemote = $false }
    }
    $EngineTargets = @("auradsp_engine")
    if ($HostRemote) { $EngineTargets += "plugin_host_x64" }
    # APO 纪律版引擎（System APO 真处理载荷，pack.py 必备资产）：
    # 同样按 CMake 缓存决定 target 是否存在（AURADSP_BUILD_APO_ENGINE 默认 ON）。
    $ApoEngine = $true
    if (Test-Path $CMakeCache) {
        $ApoCacheLine = Select-String -Path $CMakeCache -Pattern '^AURADSP_BUILD_APO_ENGINE:BOOL=(ON|OFF)' | Select-Object -First 1
        if ($ApoCacheLine -and $ApoCacheLine.Matches[0].Groups[1].Value -eq 'OFF') { $ApoEngine = $false }
    }
    if ($ApoEngine) { $EngineTargets += "auradsp_engine_apo" }

    Write-Host "  编译 $BuildType 引擎动态库$(if ($HostRemote) { '与进程外插件宿主' })..."
    Invoke-Clean (@("cmake", "--build", "--preset", $BuildPreset, "--target") + $EngineTargets + "--", "-m:$BuildJobs") `
        -Log (Join-Path $ProjectRoot "build\reports\build_engine.log")

    $EngineDll = Join-Path $EngineOutDir "$BuildType\auradsp_engine.dll"
    $EngineItem = Assert-Fresh -Path $EngineDll -Label "核心引擎 "
    $EngineSize = $EngineItem.Length
    Write-Host "  -> 核心引擎就绪: auradsp_engine.dll ($([math]::Round($EngineSize / 1MB, 2)) MB)" -ForegroundColor Green

    if ($ApoEngine) {
        $ApoEngineDll = Join-Path $EngineOutDir "$BuildType\auradsp_engine_apo.dll"
        $null = Assert-Fresh -Path $ApoEngineDll -Label "APO 引擎 "
        Write-Host "  -> APO 纪律版引擎就绪: auradsp_engine_apo.dll" -ForegroundColor Green
    }

    if ($HostRemote) {
        $PluginHostExe = Join-Path $EngineOutDir "$BuildType\plugin_host_x64.exe"
        $null = Assert-Fresh -Path $PluginHostExe -Label "64 位插件宿主 "
        Write-Host "  -> 64 位插件宿主就绪: plugin_host_x64.exe" -ForegroundColor Green

        # 双宿主架构：编译 32 位位桥宿主 plugin_host_x86.exe
        if (-not $SkipHostX86) {
            Write-Host "  配置与编译 32 位位桥插件宿主 (plugin_host_x86.exe)..."
            $X86BuildDir = Join-Path $ProjectRoot "core\desktop\windows\build-x86"
            if (-not (Test-Path $X86BuildDir)) {
                Invoke-Clean @("cmake", "-S", (Join-Path $ProjectRoot "core\desktop\windows"),
                    "-B", $X86BuildDir, "-G", "Visual Studio 18 2026", "-A", "Win32") | Out-Null
            }
            Invoke-Clean @("cmake", "--build", $X86BuildDir, "--config", $BuildType,
                "--target", "plugin_host_x86", "--", "-m:$BuildJobs") `
                -Log (Join-Path $ProjectRoot "build\reports\build_host_x86.log")
            $PluginHostX86Exe = Join-Path $EngineOutDir "$BuildType\plugin_host_x86.exe"
            if (Test-Path $PluginHostX86Exe) {
                $null = Assert-Fresh -Path $PluginHostX86Exe -Label "32 位位桥插件宿主 "
                Write-Host "  -> 32 位位桥插件宿主就绪: plugin_host_x86.exe" -ForegroundColor Green
            }
            else {
                Write-Host "  -> 警告: plugin_host_x86.exe 未生成（32 位插件将不可用）" -ForegroundColor DarkYellow
            }
        }
    }
    else {
        Write-Host "  -> AURADSP_PLUGIN_HOST_REMOTE=OFF：跳过进程外插件宿主（引擎走进程内路径）" -ForegroundColor DarkGray
    }
}
else {
    Write-Host "`n[2/6] 已跳过核心引擎编译 (-SkipEngine)" -ForegroundColor DarkGray
}

# -------------------------------------------------------------------------
# Step 3: C++ 驱动与常驻桥编译 (auravm / auravaio / auraasio)
# -------------------------------------------------------------------------
if (-not $SkipDrivers) {
    Write-Host "`n[3/6] 检查与编译 C++ 驱动常驻桥..." -ForegroundColor Yellow
    $DriversOutDir = Join-Path $ProjectRoot "core\desktop\windows-drivers\out"

    Write-Host "  配置 CMake (预设 windows-x64；桥与引擎同一构建树)..."
    Invoke-Clean (@("cmake") + $ConfigureArgs) `
        -Log (Join-Path $ProjectRoot "build\reports\cmake_configure_drivers.log") | Out-Null

    Write-Host "  编译桥接动态库 (auradsp_bridges: vm / vaio / asio)..."
    Invoke-Clean @("cmake", "--build", "--preset", $BuildPreset, "--target", "auradsp_bridges", "--", "-m:$BuildJobs") `
        -Log (Join-Path $ProjectRoot "build\reports\build_bridges.log")

    Write-Host "  编译 ASIO 虚拟驱动 (auraasio_driver，发行包必需)..."
    Invoke-Clean @("cmake", "--build", "--preset", $BuildPreset, "--target", "auraasio_driver", "--", "-m:$BuildJobs") `
        -Log (Join-Path $ProjectRoot "build\reports\build_asio.log")
    $AsioDrvPath = Join-Path $DriversOutDir "$BuildType\auraasio_driver.dll"
    if (Test-Path $AsioDrvPath) {
        $null = Assert-Fresh -Path $AsioDrvPath -Label "ASIO 驱动 "
        Write-Host "  -> ASIO 驱动就绪: auraasio_driver.dll" -ForegroundColor Green
    }
    else {
        Write-Host "  -> 警告: auraasio_driver.dll 未生成 (pack.py 的 driver/setup 模式将报错)" -ForegroundColor DarkYellow
    }

    foreach ($Bridge in @("auravm_bridge.dll", "auravaio_bridge.dll", "auraasio_bridge.dll")) {
        $DllPath = Join-Path $DriversOutDir "$BuildType\$Bridge"
        if (Test-Path $DllPath) {
            $null = Assert-Fresh -Path $DllPath -Label "桥接模块 "
            Write-Host "  -> 桥接模块就绪: $Bridge" -ForegroundColor Green
        }
        else {
            Write-Host "  -> 警告: $Bridge 未生成 (如非必须模式可跳过)" -ForegroundColor DarkYellow
        }
    }
}
else {
    Write-Host "`n[3/6] 已跳过驱动常驻桥编译 (-SkipDrivers)" -ForegroundColor DarkGray
}

# -------------------------------------------------------------------------
# Step 3b: 编译 smoke 门禁依赖的测试专用目标
# -------------------------------------------------------------------------
# `test/runner.py --smoke` 里有 13 个用例依赖一批独立的小型测试程序
# （test_plugin_chain / test_host_quarantine / test_dll_dirs / rt_drain_test /
# vaio_pump_wait_test / vm_detect / vm_pump_test / vm_parallel_test /
# apo_inspect / silence_gate_test / AuraApo …）。这些目标不在发行目标集里，
# 标准构建不会产出，于是**干净构建后跑门禁必然 FAIL 13 项**——
# 与代码质量无关，纯粹是前置产物缺失。
# 故把它们并入构建流水线：门禁要跑，先把门禁要用的东西建出来。
if (-not $SkipDrivers) {
    Write-Host "`n[3b/6] 编译 smoke 门禁依赖的测试目标..." -ForegroundColor Yellow
    $TestTargets = @(
        "test_plugin_chain", "test_host_quarantine", "test_dll_dirs",
        "rt_drain_test", "vaio_pump_wait_test", "vm_detect",
        "vm_pump_test", "vm_parallel_test", "apo_inspect",
        "silence_gate_test", "AuraApo", "apo_config"
    )
    Invoke-Clean (@("cmake", "--build", "--preset", $BuildPreset, "--target") + $TestTargets + "--", "-m:$BuildJobs") `
        -Log (Join-Path $ProjectRoot "build\reports\build_test_targets.log")
    # 校验产物：多数是 .exe，AuraApo 是 DLL（APO 驱动），按实际扩展名找。
    $Missing = @()
    foreach ($t in $TestTargets) {
        $ext = if ($t -eq "AuraApo") { ".dll" } else { ".exe" }
        $hit = @(Get-ChildItem -Path (Join-Path $ProjectRoot "core\desktop") -Filter "$t$ext" `
            -Recurse -File -ErrorAction SilentlyContinue)
        if ($hit.Count -eq 0) { $Missing += "$t$ext" }
    }
    if ($Missing.Count -gt 0) {
        throw "smoke 门禁依赖的测试目标未产出: $($Missing -join ', ')"
    }
    Write-Host "  -> 测试目标就绪: $($TestTargets.Count) 个" -ForegroundColor Green
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
    }
    else {
        $FlutterArgs += "--debug"
    }

    Write-Host "  执行: flutter $($FlutterArgs -join ' ')..."
    # Flutter 的 Windows 构建同样经 MSBuild 调编译器，环境必须先归一化
    Invoke-Clean (@("flutter") + $FlutterArgs) `
        -Log (Join-Path $ProjectRoot "build\reports\build_flutter.log")

    Set-Location $ProjectRoot
    $RunnerOutDir = Join-Path $FlutterAppDir "build\windows\x64\runner\$BuildType"
    $AppExe = Join-Path $RunnerOutDir "auradsp_app.exe"
    if (-not (Test-Path $AppExe)) {
        throw "Flutter 构建完成但未找到可执行文件: $AppExe"
    }
    Write-Host "  -> 桌面端主程序构建成功: auradsp_app.exe" -ForegroundColor Green
}
else {
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
    # 分批删除：整树一次性 Remove-Item -Recurse 会一次性带走上千个文件，
    # 既触发环境的批量删除保护，也让失败点难以定位。按批删完再清空目录。
    $BatchSize = 300
    $AllFiles = @(Get-ChildItem -Path $DistPortable -Recurse -File -Force -ErrorAction SilentlyContinue)
    for ($i = 0; $i -lt $AllFiles.Count; $i += $BatchSize) {
        $end = [math]::Min($i + $BatchSize, $AllFiles.Count)
        Remove-Item -Path $AllFiles[$i..($end - 1)].FullName -Force -ErrorAction SilentlyContinue
    }
    # 再自底向上清空目录（先子后父，避免非空目录删不掉）
    $AllDirs = @(Get-ChildItem -Path $DistPortable -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($d in $AllDirs) {
        Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $DistPortable -Recurse -Force -ErrorAction SilentlyContinue
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

# 绿色目录自包含化：把 driver/ 驱动资产与根 ASIO 本体补进分发
# 目录，使其与便携 zip / 安装载荷同布局——直接打开目录里的应用
# 即可测全部驱动面板，不必再解压便携包（pack.py 的 staging
# 模式与打包共用同一组装函数）。资产缺失（如 -SkipDrivers 未
# 构建驱动）或驱动陈旧时仅警告不中断：目录仍可测非驱动功能。
$PackPy = Join-Path $ProjectRoot "installer\windows\pack.py"
if (Get-Command python -ErrorAction SilentlyContinue) {
    Write-Host "  补齐 dist 目录驱动资产 (pack.py --mode staging)..."
    python $PackPy --mode staging --staging $DistPortable
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  -> 警告: driver 资产补齐未完成，dist 目录可能缺 driver/（详见上方 pack 输出）" -ForegroundColor DarkYellow
    }
}
else {
    Write-Host "  -> 警告: 未找到 python，跳过 driver 资产补齐（dist 目录缺 driver/）" -ForegroundColor DarkYellow
}

# 产物的规范化（2026-11-05）：写 build-info.txt（版本 / 提交 / 分支 /
# 工作区状态 / 顶层二进制 SHA256），使绿色包可追溯。
Write-Host "  写入发行产物清单 (build-info.txt)..."
$ManifestPy = Join-Path $ProjectRoot "tools\bin\dist_manifest.py"
if (Get-Command python -ErrorAction SilentlyContinue) {
    python $ManifestPy --dist-dir $DistPortable
}
else {
    Write-Host "  -> 警告: 未找到 python，跳过 build-info.txt（产物本身已就绪）" -ForegroundColor DarkYellow
}

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
