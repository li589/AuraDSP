# 驱动测试签名。
#
# 为什么不用 `signtool /sm /s My /sha1 <thumbprint>`：在新版 signtool 上这组
# 参数**选不到证书**——报 "No certificates were found that met all the given
# criteria"，而证书明明就在 LocalMachine\My 里。根因是 F999F91D（modern 轨
# 证书）的 **KeyUsage 为空**，不满足 signtool 对代码签名证书的筛选；同名的
# 0C46E213（legacy 轨）有完整 KeyUsage，于是 `/a` 自动选证书时总是选到它。
# 11-05 那轮装到目标机上的驱动正是 0C46E213 签的（与现象吻合）。
#
# 这里改用 `/a` 自动选证书 + **签后校验**：把实际选中的指纹打印出来并与期望
# 指纹比对，不一致时给出警告而不是静默用错证书。两张证书在目标机
# （vm-win10）的 LocalMachine\Root / TrustedPublisher 里都受信任，且
# `bcdedit /enum {current}` 显示 testsigning=Yes，故二者都可用。
#
# 注意：内核驱动(.sys) 必须用 signtool 签——PowerShell 的
# Set-AuthenticodeSignature 不支持内核驱动格式（会报 UnknownError）。
$thumbModern = "F999F91D3A55AA507C512CB5B0AE89B7E4D23D2E"
$thumbLegacy = "0C46E21397FBA2D75BFADA8DE4D7D52FF0B8B645"

$signtool = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.28000.0\x64\signtool.exe"
if (-not (Test-Path $signtool)) {
    $signtool = (Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Filter "signtool.exe" -Recurse |
        Where-Object { $_.FullName -like "*x64*" } | Select-Object -First 1).FullName
}
if (-not $signtool -or -not (Test-Path $signtool)) {
    Write-Error "signtool.exe not found"
    exit 1
}
Write-Host "Using SignTool: $signtool"

# 脚本位于 <repo>/core/desktop/windows-drivers/01_vaio_driver/，向上 4 级才是仓库根
$root = $PSScriptRoot
for ($i = 0; $i -lt 4; $i++) { $root = Split-Path -Parent $root }
$base = Join-Path $root "core\desktop\windows-drivers\01_vaio_driver"

function Sign-Target {
    param([string]$Path, [string]$ExpectThumb, [string]$Algorithm, [string]$Label)
    if (-not (Test-Path $Path)) {
        Write-Host "  跳过（不存在）: $Path"
        return
    }
    Write-Host "签名[$Label]: $Path"
    & $signtool sign /v /a /fd $Algorithm $Path | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "签名失败 (exit=$LASTEXITCODE): $Path"
        exit 1
    }
    $sig = Get-AuthenticodeSignature $Path
    $actual = if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { "<无>" }
    # 判定用「签名者读得到」而不是「Status=Valid」：
    # 内核驱动(.sys) 的签名格式 Get-AuthenticodeSignature 认不全，会报
    # UnknownError；而自签测试证书在**构建机**上不在 Root 存储里，
    # 链验证必然失败——信任链要到目标机才成立。签名是否写入，看签名者。
    if (-not $sig.SignerCertificate) {
        Write-Error ("签名未写入: {0}  Status={1}" -f $Path, $sig.Status)
        exit 1
    }
    Write-Host "  -> OK  Status=$($sig.Status)  签名者=$actual"
    if ($ExpectThumb -and $actual -ne $ExpectThumb) {
        Write-Warning ("选中的证书与预期不同（期望 {0}，实际 {1}）。两张测试证书在目标机" -f $ExpectThumb, $actual)
        Write-Warning "的 Root/TrustedPublisher 里都受信任，功能上等效，但请知悉差异。"
    }
}

Write-Host "[modern] 期望证书 $thumbModern / SHA256"
Sign-Target (Join-Path $base "modern\x64\Release\AuraVaioDriver\AuraVaioDriver.sys") $thumbModern "SHA256" "modern"
Sign-Target (Join-Path $base "modern\x64\Release\AuraVaioDriver\auravaiodriver.cat") $thumbModern "SHA256" "modern"

Write-Host "[legacy] 期望证书 $thumbLegacy / SHA1"
Sign-Target (Join-Path $base "legacy\x64\Release\AuraVaioDriverLegacy\AuraVaioDriver.sys") $thumbLegacy "SHA1" "legacy"
Sign-Target (Join-Path $base "legacy\x64\Release\AuraVaioDriverLegacy\auravaiodriver.cat") $thumbLegacy "SHA1" "legacy"

Write-Host "全部目标签名完成"
