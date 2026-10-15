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
  -Action install   需管理员：可选测试签名 → pnputil 入栈 → devcon 建节点 → 复验。
  -Action uninstall 需管理员：移除设备节点 + 从 DriverStore 删除驱动包。

  安全口径：install / uninstall 都需要管理员，并且会明确告知将要执行的动作；
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
#>
param(
    [ValidateSet('modern', 'legacy')] [string]$Track  = 'modern',
    [ValidateSet('Debug', 'Release')] [string]$Config = 'Debug',
    [ValidateSet('status', 'install', 'uninstall')] [string]$Action = 'status',

    # install: 跳过测试签名步骤，直接把包交给 PnP（包必须已可信签名）
    [switch]$SkipSign,

    # 生成/复用测试证书时使用的主题名
    [string]$CertSubject = 'CN=AuraDSP Test Signing',

    # uninstall: 顺带删除上面那张测试证书（含 Root / TrustedPublisher 两份）
    [switch]$RemoveTestCert
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
        "$env:ProgramFiles(x86)\Windows Kits\10\Tools\10.0.28000.0\x64\devcon.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Tools\x64\devcon.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Tools\amd64\devcon.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Tools\10.0.26100.0\x64\devcon.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
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
    Write-Host '[4] 已安装的设备节点'
    $devs = @(Get-PnpDevice -ErrorAction SilentlyContinue |
              Where-Object { $_.FriendlyName -like $DeviceName -or $_.InstanceId -match 'AuraVAIO' -or $_.InstanceId -match 'AuraVaioDriver' })
    if ($devs.Count -eq 0) {
        Write-Host '  （未发现 AuraVAIO 设备）' -ForegroundColor Yellow
    } else {
        $devs | Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host '  → 验收判据：Status 为 OK' -ForegroundColor Cyan
    }

    Write-Host ''
    Write-Host '[5] DriverStore 中的驱动包'
    if ($IsAdmin) {
        $oem = & "$env:SystemRoot\System32\pnputil.exe" /enum-drivers 2>&1 | Out-String
        if ($oem -match 'AuraVaioDriver|auravaiodriver') {
            Write-Host '  已在 DriverStore 中' -ForegroundColor Green
        } else {
            Write-Host '  DriverStore 中无 AuraVAIO' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  需管理员才能枚举 DriverStore' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '[6] 音频端点（验收 ①：出现在输出设备列表）'
    try {
        $eps = @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue)
        $mine = @($eps | Where-Object { $_.FriendlyName -like $DeviceName })
        Write-Host ("  本机 OK 音频端点共 {0} 个；名称含 AuraVAIO 的 {1} 个" -f $eps.Count, $mine.Count)
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
    if (-not $IsAdmin) { throw 'install 需要管理员权限，请以管理员身份重跑本脚本。' }
    if (-not (Test-Path $InfPath)) { throw "找不到 INF: $InfPath（先构建）" }

    $devcon = Find-Devcon
    $signtool = Find-SignTool

    Write-Host ''
    Write-Host '即将执行：' -ForegroundColor Yellow
    Write-Host "  1) 测试签名       : $(if ($SkipSign -or -not $signtool) { '跳过' } else { $CatPath })"
    Write-Host "  2) 驱动入 DriverStore: pnputil /add-driver `"$InfPath`" /install"
    Write-Host "  3) 创建设备节点   : devcon install `"$InfPath`" $HwId"
    Write-Host ''

    if (-not $SkipSign) {
        if (-not $signtool) { throw '找不到 signtool.exe；请用 -SkipSign 或自行签名后重试。' }
        $ok = New-TestSignature -SignTool $signtool
        if (-not $ok) { throw '测试签名前置条件未满足（testsigning 未开），已停止。' }
    }

    Write-Host '[1/3] 把驱动包装入 DriverStore'
    & "$env:SystemRoot\System32\pnputil.exe" /add-driver $InfPath /install
    if ($LASTEXITCODE -ne 0) { throw "pnputil 失败 (exit $LASTEXITCODE)" }

    Write-Host ''
    Write-Host '[2/3] 创建 root 枚举设备节点'
    if ($devcon) {
        & $devcon install $InfPath $HwId
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  devcon install $HwId 失败，改用备用硬件 ID $HwIdAlt" -ForegroundColor Yellow
            & $devcon install $InfPath $HwIdAlt
        }
    } else {
        Write-Host '  未找到 devcon.exe，无法自动建节点。请手动执行：' -ForegroundColor Yellow
        Write-Host "    devcon install `"$InfPath`" $HwId" -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '[3/3] 复验'
    Start-Sleep -Seconds 2
    Show-Status
}

#=============================================================================
# uninstall
#=============================================================================

function Invoke-Uninstall {
    if (-not $IsAdmin) { throw 'uninstall 需要管理员权限，请以管理员身份重跑本脚本。' }

    $devcon = Find-Devcon

    Write-Host ''
    Write-Host '即将执行：' -ForegroundColor Yellow
    Write-Host "  1) 移除设备节点 : devcon remove $HwId ($HwIdAlt)"
    Write-Host '  2) 从 DriverStore 删除 : pnputil /delete-driver auravaiodriver.inf /uninstall /force'
    if ($RemoveTestCert) { Write-Host "  3) 删除测试证书 : $CertSubject（Root + TrustedPublisher）" } else { Write-Host '  3) 保留测试证书（-RemoveTestCert 可删）' }
    Write-Host ''

    Write-Host '[1/2] 移除设备节点'
    if ($devcon) {
        foreach ($id in @($HwId, $HwIdAlt)) {
            # 没装过时 devcon 会返回非零，视为正常，不中断。
            & $devcon remove $id 2>&1 | ForEach-Object { Write-Host "    $_" }
        }
    } else {
        Write-Host '  未找到 devcon.exe，跳过节点移除' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '[2/2] 从 DriverStore 删除驱动包'
    & "$env:SystemRoot\System32\pnputil.exe" /delete-driver auravaiodriver.inf /uninstall /force 2>&1 |
        ForEach-Object { Write-Host "    $_" }

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
}
