<#
.SYNOPSIS
  AuraVAIO 驱动装载 / 卸载 / 状态查询（Phase 4 验收 ①：设备管理器识别 AuraVAIO）。

.DESCRIPTION
  双轨支持：-Track modern（WDK 28000，Win10 1809+/Win11）| legacy（EWDK 19041，Win7/8/8.1）。
  产物目录随轨取：modern → .\modern\x64\<Config>\AuraVaioDriver\，
  legacy → .\legacy\x64\<Config>\AuraVaioDriverLegacy\。

  为什么需要脚本而不是一条 pnputil：AuraVAIO 是 **root 枚举** 的软件设备（无硬件），
  pnputil 只把驱动包装进 DriverStore，**不会**创建设备节点；还需要 devcon
  显式创建 `Root\AuraVAIO` 才会触发 AddDevice/StartDevice。

  -Action status    只读体检（默认）：包是否存在、测试签名开关、已装设备、证书。
  -Action install   需管理员：可选测试签名 → 幂等清理 → pnputil 入栈 → devcon 建节点 → 复验。
  -Action uninstall 需管理员：移除全部设备节点 + 从 DriverStore 删除全部同名驱动包。
  -Action cleanup   需管理员：把环境收敛到「1 个 MEDIA 节点 + 1 份在用驱动包」，
                    移除重复安装残留的备用 ID 节点与陈旧 oem 包；不卸载驱动。
  -DryRun           预演：只打印将移除的节点 / 驱动包清单，不做任何改动
                    （对 install / uninstall / cleanup 有效）。

  幂等口径（2026-11-09）：INF 同时声明 `Root\AuraVAIO`（主）与
  `Root\AuraVaioDriver`（备）两个硬件 ID；`devcon install` 返回非零时节点**可能
  已经建好**，旧逻辑直接 fallback 就会造出第二个节点。现在安装前清理改为
  按硬件 ID 全量枚举 + 精确移除（不解析 devcon 输出文本），fallback 只在
  「节点数仍为 0」时发生，安装结束后再收敛一次。验收判据：MEDIA 节点数 == 1。

  安全口径：install / uninstall / cleanup 都需要管理员，并且会明确告知将要执行的动作；
  脚本**不会**替你重启机器——需要重启时会打印命令后停止。

.EXAMPLE
  # 只读体检（任何权限）
  .\install_driver.ps1

.EXAMPLE
  # 以管理员身份安装 modern 轨（未签名 → 先测试签名，需已开 testsigning 并重启过）
  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-File',"$PWD\install_driver.ps1",'-Action','install'

.EXAMPLE
# 卸载并清理测试证书
.\install_driver.ps1 -Action uninstall -RemoveTestCert

.EXAMPLE
  # 只读预演清理计划（不改动系统）
  .\install_driver.ps1 -Action cleanup -DryRun

.EXAMPLE
  # 实跑收敛：移除重复节点与陈旧驱动包，保留一套可用驱动
  .\install_driver.ps1 -Action cleanup
#>
param(
    [ValidateSet('modern', 'legacy')] [string]$Track  = 'modern',
    [ValidateSet('Debug', 'Release')] [string]$Config = 'Debug',
    [ValidateSet('status', 'install', 'uninstall', 'cleanup')] [string]$Action = 'status',

    # install: 跳过测试签名步骤，直接把包交给 PnP（包必须已可信签名）
    [switch]$SkipSign,

    # 生成/复用测试证书时使用的主题名
    [string]$CertSubject = 'CN=AuraDSP Project',

    # uninstall: 顺带删除上面那张测试证书（含 Root / TrustedPublisher 两份）
    [switch]$RemoveTestCert,

    # 预演：只列出将移除的节点 / 驱动包，不做任何改动
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

#=============================================================================
# 环境
#=============================================================================

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$Root = $PSScriptRoot

$PackageDir = if ($Track -eq 'modern') {
    Join-Path $Root "modern\x64\$Config\AuraVaioDriver"
} else {
    Join-Path $Root "legacy\x64\$Config\AuraVaioDriverLegacy"
}
$InfPath  = Join-Path $PackageDir 'AuraVaioDriver.inf'
$SysPath  = Join-Path $PackageDir 'AuraVaioDriver.sys'
$CatPath  = Join-Path $PackageDir 'auravaiodriver.cat'

# devcon 是创建 root 枚举设备节点的标准工具；WDK 会把它放在 Tools 下的版本目录里。
# 顺带排查几个历史位置（10.0.28000.0 / x64 / amd64）。
function Find-Devcon {
    $candidates = @(
        (Join-Path $PackageDir 'devcon.exe'),
        (Join-Path $Root 'devcon.exe'),
        "E:\Program Files\Windows Kits\10\Tools\x64\devcon.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Tools\10.0.28000.0\x64\devcon.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Tools\x64\devcon.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Tools\amd64\devcon.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Tools\10.0.26100.0\x64\devcon.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command devcon.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 显式指定优先（跨机同步脚本时常用）
    if ($env:AURADSP_DEVCON -and (Test-Path $env:AURADSP_DEVCON)) { return $env:AURADSP_DEVCON }
    # 兜底：驱动目录树内随包分发的 devcon.exe（不硬编码某台机器的盘符）
    $localHit = Get-ChildItem -Path $Root -Filter 'devcon.exe' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
    if ($localHit) { return $localHit.FullName }
    return $null
}

function Find-SignTool {
    $binRoot = "$env:ProgramFiles(x86)\Windows Kits\10\bin"
    if (-not (Test-Path $binRoot)) { return $null }
    $hit = Get-ChildItem $binRoot -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -match '\\x64\\' } |
           Sort-Object FullName -Descending | Select-Object -First 1
    return $hit.FullName
}

# 设备节点使用的硬件 ID 必须与 INF 的 [Manufacturer] 段一致。
$HwId       = 'Root\AuraVAIO'
$HwIdAlt    = 'Root\AuraVaioDriver'
$DeviceName = 'AuraVAIO*'

#=============================================================================
# 设备节点 / DriverStore 枚举与收敛（不解析 devcon 输出文本）
#=============================================================================

function Get-AuraMediaNodes {
    # 只认两个硬件 ID；同名但不属于本驱动的 MEDIA 设备不会被误判。
    $all = @(Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue)
    $result = @()
    foreach ($d in $all) {
        $hw = @((Get-PnpDeviceProperty -InstanceId $d.InstanceId `
                    -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data)
        $matched = @($hw | Where-Object { $_ -eq $HwId -or $_ -eq $HwIdAlt } | Select-Object -First 1)
        if ($matched.Count -gt 0) {
            $result += [pscustomobject]@{
                InstanceId   = $d.InstanceId
                HardwareId   = $matched[0]
                Status       = $d.Status
                FriendlyName = $d.FriendlyName
            }
        }
    }
    return $result
}

function Get-AuraDriverPackages {
    # 解析 pnputil /enum-drivers，兼容中英文键名；每次 add-driver 都会留一份 oem 包。
    $out = & "$env:SystemRoot\System32\pnputil.exe" /enum-drivers 2>&1 | Out-String
    $blocks = [regex]::Split($out, "(?=发布名称\s*:|Published Name\s*:)")
    $result = @()
    foreach ($b in $blocks) {
        if ($b -notmatch 'auravaiodriver\.inf') { continue }
        $pub = ([regex]::Match($b, '(?:发布名称|Published Name)\s*:\s*(\S+)')).Groups[1].Value
        $ver = ([regex]::Match($b, '(?:驱动程序版本|Driver Version)\s*:\s*([^\r\n]+)')).Groups[1].Value.Trim()
        if ($pub) {
            $result += [pscustomobject]@{ PublishedName = $pub; DriverVersion = $ver }
        }
    }
    return $result
}

function Get-AuraInUseInf {
    param([object[]]$Nodes)
    $names = @()
    foreach ($n in @($Nodes)) {
        $v = (Get-PnpDeviceProperty -InstanceId $n.InstanceId `
                -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
        if ($v) { $names += @($v)[0] }
    }
    return @($names | Select-Object -Unique)
}

function Remove-AuraNode {
    param([string]$InstanceId, [string]$HardwareId)
    # Win10 1809+ 支持按实例 ID 精确移除，比 devcon remove <HWID> 更精确。
    $out = & "$env:SystemRoot\System32\pnputil.exe" /remove-device $InstanceId 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Host ("    pnputil 返回 {0}：{1}" -f $LASTEXITCODE, $out.Trim()) -ForegroundColor Yellow
    $devcon = Find-Devcon
    if ($devcon) {
        & $devcon remove $HardwareId 2>&1 | ForEach-Object { Write-Host "    $_" }
        return $true
    }
    return $false
}

function Invoke-Cleanup {
    param(
        [switch]$All,      # 完全清理：0 节点 / 0 包（install、uninstall 用）
        [switch]$Preview   # 只打印计划，不改动系统
    )
    if (-not $IsAdmin -and -not $Preview) {
        throw 'cleanup / install / uninstall 需要管理员权限，请提权后重跑。'
    }

    $nodes = @(Get-AuraMediaNodes)
    $pkgs  = @(Get-AuraDriverPackages)
    Write-Host ''
    Write-Host ("[清理] 当前：MEDIA 节点 {0} 个 / DriverStore 同名包 {1} 个" -f $nodes.Count, $pkgs.Count) -ForegroundColor Cyan

    # 收敛模式保留主 HWID 的节点 + 它正在用的 INF；完全清理模式什么都不留。
    $keepNode = $null
    $keepPkgs = @()
    if (-not $All) {
        $primary = @($nodes | Where-Object { $_.HardwareId -eq $HwId } | Select-Object -First 1)
        if ($primary.Count -gt 0) { $keepNode = $primary[0] }
        elseif ($nodes.Count -gt 0) { $keepNode = $nodes[0] }
        if ($keepNode) { $keepPkgs = @(Get-AuraInUseInf -Nodes @($keepNode)) }
        if ($keepPkgs.Count -eq 0 -and $pkgs.Count -gt 0) {
            $keepPkgs = @(($pkgs | Sort-Object DriverVersion -Descending | Select-Object -First 1).PublishedName)
        }
    }

    $removeNodes = @($nodes | Where-Object { -not $keepNode -or $_.InstanceId -ne $keepNode.InstanceId })
    $removePkgs  = @($pkgs  | Where-Object { $keepPkgs -notcontains $_.PublishedName })

    Write-Host ("  保留节点  : {0}" -f $(if ($keepNode) { "$($keepNode.InstanceId) [$($keepNode.HardwareId)]" } else { '（无，完全清理）' }))
    Write-Host ("  保留驱动包: {0}" -f $(if ($keepPkgs.Count -gt 0) { $keepPkgs -join ', ' } else { '（无，完全清理）' }))
    Write-Host ("  将移除    : 节点 {0} 个 / 驱动包 {1} 个" -f $removeNodes.Count, $removePkgs.Count)
    foreach ($n in $removeNodes) { Write-Host ("    NODE  {0}  [{1}]" -f $n.InstanceId, $n.HardwareId) }
    foreach ($p in $removePkgs)  { Write-Host ("    PKG   {0}  ({1})" -f $p.PublishedName, $p.DriverVersion) }

    if ($Preview) {
        Write-Host '  [预演] 未做任何改动。' -ForegroundColor Yellow
        return
    }

    $failed = 0
    foreach ($n in $removeNodes) {
        Write-Host ("  移除节点 {0} ..." -f $n.InstanceId)
        if (-not (Remove-AuraNode -InstanceId $n.InstanceId -HardwareId $n.HardwareId)) { $failed++ }
    }
    foreach ($p in $removePkgs) {
        Write-Host ("  删除驱动包 {0} ..." -f $p.PublishedName)
        & "$env:SystemRoot\System32\pnputil.exe" /delete-driver $p.PublishedName /uninstall /force 2>&1 |
            ForEach-Object { Write-Host "    $_" }
    }

    Start-Sleep -Seconds 1
    $afterNodes = @(Get-AuraMediaNodes)
    $afterPkgs  = @(Get-AuraDriverPackages)
    Write-Host ("[清理后] MEDIA 节点 {0} 个 / DriverStore 同名包 {1} 个，移除失败 {2} 项" -f `
                $afterNodes.Count, $afterPkgs.Count, $failed) -ForegroundColor Cyan
    if ($All) {
        if ($afterNodes.Count -eq 0 -and $afterPkgs.Count -eq 0) {
            Write-Host '  完全清理达标（0 节点 / 0 包）。' -ForegroundColor Green
        } else {
            Write-Host '  未完全清空（部分包可能被系统占用，见上方 pnputil 输出）。' -ForegroundColor Yellow
        }
    } else {
        if ($afterNodes.Count -eq 1) {
            Write-Host '  收敛达标：MEDIA 节点数 == 1。' -ForegroundColor Green
        } else {
            Write-Host ("  未达标：MEDIA 节点数 {0}，期望 1。" -f $afterNodes.Count) -ForegroundColor Yellow
        }
    }
}

#=============================================================================
# 只读体检
#=============================================================================

function Show-Status {
    Write-Host ''
    Write-Host '=========== AuraVAIO 装载状态体检 ===========' -ForegroundColor Cyan

    Write-Host ''
    Write-Host "[1] 驱动包（Track=$Track / Config=$Config）"
    foreach ($pair in @(
        @('INF', $InfPath), @('SYS', $SysPath), @('CAT', $CatPath)
    )) {
        $name, $p = $pair
        if (Test-Path $p) {
            $f = Get-Item $p
            Write-Host ("  {0,-4} OK   {1,10:N0} B  {2}" -f $name, $f.Length, $p) -ForegroundColor Green
        } else {
            Write-Host ("  {0,-4} 缺失 {1}" -f $name, $p) -ForegroundColor Red
        }
    }
    if (-not (Test-Path $InfPath)) {
        Write-Host "  → 先构建：.\build_drivers.ps1 -Track $Track -Config $Config" -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '[2] 权限'
    Write-Host ("  当前会话管理员: {0}" -f $IsAdmin) -ForegroundColor $(if ($IsAdmin) { 'Green' } else { 'Yellow' })
    if (-not $IsAdmin) {
        Write-Host '  → install / uninstall 需要提权运行本脚本' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '[3] 测试签名开关（未签名 .sys 必须开）'
    if ($IsAdmin) {
        $bcd = & "$env:SystemRoot\System32\bcdedit.exe" /enum '{current}' 2>&1
        $ts  = $bcd | Select-String -Pattern '^\s*testsigning\s+(\S+)'
        if ($ts) {
            $v = $ts.Matches[0].Groups[1].Value
            Write-Host ("  testsigning = {0}" -f $v) -ForegroundColor $(if ($v -eq 'Yes') { 'Green' } else { 'Yellow' })
        } else {
            Write-Host '  testsigning = <未设置>（等同 No）' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  需管理员才能读 bcdedit' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '[4] 已安装的 MEDIA 设备节点（按硬件 ID 精确匹配）'
    $nodes = @(Get-AuraMediaNodes)
    if ($nodes.Count -eq 0) {
        Write-Host '  （未发现 AuraVAIO 设备节点）' -ForegroundColor Yellow
    } else {
        $nodes | Select-Object Status, HardwareId, InstanceId | Format-Table -AutoSize | Out-String | Write-Host
    }
    if ($nodes.Count -eq 1) {
        Write-Host '  → 验收判据：MEDIA 节点数 == 1，通过' -ForegroundColor Green
    } else {
        Write-Host ("  → 验收判据：MEDIA 节点数 == 1，当前 {0} 个（重复安装残留，跑 -Action cleanup 收敛）" -f $nodes.Count) -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '[5] DriverStore 中的同名驱动包'
    $pkgs = @(Get-AuraDriverPackages)
    Write-Host ("  auravaiodriver.inf 共 {0} 份：{1}" -f $pkgs.Count,
        $(if ($pkgs.Count -gt 0) { ($pkgs | ForEach-Object { $_.PublishedName }) -join ', ' } else { '（无）' }))
    if ($pkgs.Count -gt 1) {
        Write-Host '  → 存在历次安装残留的旧包，跑 -Action cleanup 收敛到 1 份' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '[6] 音频端点（验收 ①：出现在输出设备列表）'
    try {
        $eps = @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue)
        # 端点名形如「扬声器 (AuraVAIO Virtual Audio Device)」，必须用包含匹配；
        # 旧写法 -like 'AuraVAIO*' 永远匹配不到，会报出「0 个」的假阴性。
        $mine = @($eps | Where-Object { $_.FriendlyName -like '*AuraVAIO*' })
        Write-Host ("  本机 OK 音频端点共 {0} 个；名称含 AuraVAIO 的 {1} 个" -f $eps.Count, $mine.Count)
        Write-Host '  → 每个 MEDIA 节点派生 1 个扬声器 + 1 个麦克风端点；端点数 ≈ 节点数 × 2' -ForegroundColor DarkGray
        if ($mine.Count -gt 0) { $mine | Select-Object FriendlyName, InstanceId | Format-Table -AutoSize | Out-String | Write-Host }
    } catch {
        Write-Host "  枚举音频端点失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host ''
}

#=============================================================================
# 测试签名
#=============================================================================

function New-TestSignature {
    param([string]$SignTool)

    Write-Host ''
    Write-Host '[签名] 未签名驱动需要测试签名 + testsigning 开关' -ForegroundColor Cyan

    # 复用已存在的证书，避免每次 install 都堆一张。
    $cert = Get-ChildItem Cert:\LocalMachine\My |
            Where-Object { $_.Subject -eq $CertSubject } |
            Sort-Object NotAfter -Descending | Select-Object -First 1

    if (-not $cert) {
        Write-Host "  生成自签名测试证书 $CertSubject"
        $cert = New-SelfSignedCertificate `
                    -Type CodeSigningCert `
                    -Subject $CertSubject `
                    -CertStoreLocation 'Cert:\LocalMachine\My' `
                    -KeyUsage DigitalSignature `
                    -KeyLength 2048 `
                    -NotAfter (Get-Date).AddYears(3) `
                    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3,1.3.6.1.5.5.7.3.3')
    } else {
        Write-Host "  复用已有证书: $($cert.Thumbprint)"
    }

    # Root：让链可信；TrustedPublisher：让 PnP 不再弹「是否信任此发布者」。
    foreach ($store in 'Root', 'TrustedPublisher') {
        $target = "Cert:\LocalMachine\$store"
        $already = Get-ChildItem $target | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if (-not $already) {
            Write-Host "  导入 $store"
            $tmp = Join-Path $env:TEMP "aura_test_$($cert.Thumbprint).cer"
            Export-Certificate -Cert $cert -FilePath $tmp | Out-Null
            Import-Certificate -FilePath $tmp -CertStoreLocation $target | Out-Null
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "  签名 $CatPath"
    & $SignTool sign /v /fd SHA256 /a /sha1 $cert.Thumbprint $CatPath
    if ($LASTEXITCODE -ne 0) { throw "signtool 签名失败 (exit $LASTEXITCODE)" }

    # testsigning 未开时给命令但**不擅自改启动配置**。
    $bcd = & "$env:SystemRoot\System32\bcdedit.exe" /enum '{current}' 2>&1
    $ts  = $bcd | Select-String -Pattern '^\s*testsigning\s+Yes'
    if (-not $ts) {
        Write-Host ''
        Write-Host '  !! testsigning 未开启，驱动无法加载。请手动执行后重启：' -ForegroundColor Yellow
        Write-Host '       bcdedit /set testsigning on' -ForegroundColor Yellow
        Write-Host '       shutdown /r /t 0' -ForegroundColor Yellow
        Write-Host '  （脚本不代改启动配置，也不代重启）' -ForegroundColor DarkGray
        return $false
    }
    return $true
}

#=============================================================================
# install
#=============================================================================

function Invoke-Install {
    if (-not $IsAdmin -and -not $DryRun) { throw 'install 需要管理员权限，请以管理员身份重跑本脚本。' }
    if (-not $DryRun -and -not (Test-Path $InfPath)) { throw "找不到 INF: $InfPath（先构建）" }

    $devcon = Find-Devcon
    $signtool = Find-SignTool

    Write-Host ''
    Write-Host '即将执行：' -ForegroundColor Yellow
    Write-Host "  1) 测试签名       : $(if ($SkipSign -or -not $signtool) { '跳过' } else { $CatPath })"
    Write-Host  '  2) 幂等清理       : 移除全部 AuraVAIO 节点 + 全部同名 oem 包'
    Write-Host "  3) 驱动入 DriverStore: pnputil /add-driver `"$InfPath`" /install"
    Write-Host "  4) 创建设备节点 + 收敛到单节点: devcon install `"$InfPath`" $HwId"
    Write-Host ''

    # 预演模式不签名（签名会改写 .cat），也不要求 signtool / testsigning。
    if (-not $DryRun) {
        if (-not $SkipSign) {
            if (-not $signtool) { throw '找不到 signtool.exe；请用 -SkipSign 或自行签名后重试。' }
            $ok = New-TestSignature -SignTool $signtool
            if (-not $ok) { throw '测试签名前置条件未满足（testsigning 未开），已停止。' }
        }
    }

    # 安装前把环境清成「0 节点 / 0 同名包」(DRV 规约)，避免重复安装层层叠加。
    # 清完必须能重建节点：没有 devcon 时拒绝实跑，防止把机器清成不可用。
    if (-not $devcon -and -not $DryRun) {
        throw '未找到 devcon.exe：完全清理后无法重建 root 设备节点，已停止。请放置 devcon.exe（或设环境变量 AURADSP_DEVCON），或改用 -Action cleanup 只做收敛。'
    }

    Write-Host ''
    Write-Host '[1/4] 安装前幂等清理' -ForegroundColor Cyan
    if ($DryRun) { Invoke-Cleanup -All -Preview } else { Invoke-Cleanup -All }
    if ($DryRun) {
        Write-Host '  [预演] 后续 add-driver / devcon install 步骤跳过。' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host '[2/4] 把驱动包装入 DriverStore'
    & "$env:SystemRoot\System32\pnputil.exe" /add-driver $InfPath /install
    if ($LASTEXITCODE -ne 0) { throw "pnputil 失败 (exit $LASTEXITCODE)" }

    Write-Host ''
    Write-Host '[3/4] 创建 root 枚举设备节点'
    if ($devcon) {
        & $devcon install $InfPath $HwId
        # devcon 返回非零不代表节点没建好：按实际节点数决定是否 fallback。
        $created = @(Get-AuraMediaNodes)
        if ($created.Count -eq 0) {
            Write-Host "  $HwId 未建成节点，改用备用硬件 ID $HwIdAlt" -ForegroundColor Yellow
            & $devcon install $InfPath $HwIdAlt
        }
    }

    Write-Host ''
    Write-Host '[4/4] 复验 + 收敛到单节点' -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    Invoke-Cleanup
    Show-Status
}

#=============================================================================
# uninstall
#=============================================================================

function Invoke-Uninstall {
    if (-not $IsAdmin -and -not $DryRun) { throw 'uninstall 需要管理员权限，请以管理员身份重跑本脚本。' }

    Write-Host ''
    Write-Host '即将执行：' -ForegroundColor Yellow
    Write-Host '  1) 移除全部 AuraVAIO MEDIA 设备节点（主 + 备两个硬件 ID）'
    Write-Host '  2) 删除 DriverStore 中全部 auravaiodriver.inf 包（逐份 oemXX.inf）'
    if ($RemoveTestCert) { Write-Host "  3) 删除测试证书 : $CertSubject（Root + TrustedPublisher）" } else { Write-Host '  3) 保留测试证书（-RemoveTestCert 可删）' }
    Write-Host ''

    if ($DryRun) { Invoke-Cleanup -All -Preview } else { Invoke-Cleanup -All }
    if ($DryRun) {
        Write-Host '  [预演] 证书清理跳过。' -ForegroundColor Yellow
        return
    }

    if ($RemoveTestCert) {
        Write-Host ''
        Write-Host '[清理] 删除测试证书'
        foreach ($store in 'Root', 'TrustedPublisher', 'My') {
            Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -eq $CertSubject } |
                ForEach-Object {
                    Write-Host "  移除 $store\$($_.Thumbprint)"
                    Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue
                }
        }
    }

    Write-Host ''
    Write-Host '卸载完成。设备管理器应已无 AuraVAIO 条目。' -ForegroundColor Green
}

#=============================================================================
# 入口
#=============================================================================

switch ($Action) {
    'status'    { Show-Status }
    'install'   { Invoke-Install }
    'uninstall' { Invoke-Uninstall }
    'cleanup'   { if ($DryRun) { Invoke-Cleanup -Preview } else { Invoke-Cleanup } }
}
