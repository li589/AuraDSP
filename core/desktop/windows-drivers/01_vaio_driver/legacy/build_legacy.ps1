<#
.SYNOPSIS
  LEGACY line build: build the AuraVAIO driver inside the EWDK 19041 environment
  (VS2019 BuildTools 16.7 + MSVC v14.23), targeting Win7 SP1 / 8 / 8.1.
.DESCRIPTION
  Builds AuraVaioDriverLegacy.vcxproj, which compiles the SAME sources as the
  modern line (../src/*.cpp|*.h -- the single source of truth) into its own
  output directory, so the two tracks no longer overwrite each other's
  AuraVaioDriver.sys / .inf / .cat.

  Prereq: mount the EWDK 19041 ISO (or extract it) and set
      $env:AURA_EWDK19041 = "<EWDK root>"     # root must contain BuildEnv\SetupBuildEnv.cmd

  Where the Win7-specific settings now live (ALL baked into the .vcxproj -- the command
  line no longer overrides anything, so the project is also buildable straight from the
  VS2019 IDE inside the EWDK):
      WindowsTargetPlatformVersion=10.0.19041.0    (matches the EWDK's in-box SDK/WDK build)
      TargetVersion=Windows7                        (min OS = Win7 -> build-older/run-newer)
      DriverTargetPlatform=Desktop                  (Universal is Win10+ only)
      KMDF_VERSION_MAJOR=1 / KMDF_VERSION_MINOR=11  (KMDF 1.11 = last version that supports Win7;
                                                     WDK would otherwise default a Win7 target to 1.9)
      TargetName=AuraVaioDriver                     (the INF references AuraVaioDriver.sys)
  Notes:
    - The EWDK is self-contained and ships the real WindowsKernelModeDriver10.0 toolset for
      VS2019 BuildTools (v160), so no hand-authored toolset is needed here (that was a VS2026 gap).
    - SetupBuildEnv.cmd (NOT LaunchBuildEnv.cmd, which opens a `/k` shell) configures the current
      cmd session: it calls vsdevcmd.bat and sets WDKContentRoot/WindowsSdkDir.
    - If the WDK toolset is ever reported missing (MSB8020), unpack %KitsRoot10%\Vsix\VS2019\WDK.vsix
      into the BuildTools MSBuild tree (OSR workaround). The EWDK normally already contains it.
#>
param([string]$Config="Debug", [string]$Platform="x64")

# Fix MSB6001: collapse duplicate Path/PATH inherited from the host process env.
# NOTE: the restore must NOT live inside the try -- Remove-Item on the second
# spelling throws "path-not-found" once the first one is gone, and a plain catch
# would skip the restore, leaving PATH empty and breaking bare `cmd.exe`.
$cleanPath = [string]$env:Path
Remove-Item env:PATH -ErrorAction SilentlyContinue
Remove-Item env:Path -ErrorAction SilentlyContinue
if ($cleanPath) { $env:Path = $cleanPath }

$ewdk = $env:AURA_EWDK19041
if (-not $ewdk) { Write-Error 'Set $env:AURA_EWDK19041 = "<EWDK root>" first.'; exit 1 }
$setup = Join-Path $ewdk 'BuildEnv\SetupBuildEnv.cmd'
if (-not (Test-Path $setup)) { Write-Error "Not found: $setup"; exit 1 }

$proj = Join-Path $PSScriptRoot 'AuraVaioDriverLegacy.vcxproj'
if (-not (Test-Path $proj)) { Write-Error "Not found: $proj"; exit 1 }

# The Win7 / KMDF-1.11 / Desktop-platform settings are baked into the .vcxproj, so
# the command line passes no property overrides. SkipPackageVerification mirrors the
# modern track (INF verification is a validation gate, not needed to emit the .sys).
$msbArgs = "/p:Configuration=$Config /p:Platform=$Platform /p:SkipPackageVerification=true"

# Generate a temp .cmd to avoid nested-quote issues; configure env then run msbuild in the SAME session.
$cmdFile = "D:\temp_desktop\Proj\JamesDSP\.tmp\wdk-install\aura_build_legacy.cmd"
$lines = @(
    "@echo off",
    "call `"$setup`" amd64",
    "if errorlevel 1 (echo [legacy] SetupBuildEnv failed & exit /b 1)",
    "msbuild `"$proj`" $msbArgs"
)
Set-Content -Path $cmdFile -Value $lines -Encoding ASCII

Write-Host "[legacy] EWDK=$ewdk" -ForegroundColor Cyan
Write-Host "[legacy] cmd =$cmdFile" -ForegroundColor Cyan

# Absolute path: `cmd` must be locatable even if the host PATH is in a bad state.
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
if (-not (Test-Path $cmdExe)) { Write-Error "Not found: $cmdExe"; exit 1 }
& $cmdExe /c $cmdFile
exit $LASTEXITCODE
