param(
    [Parameter(Mandatory = $true)][int]$TargetPid,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$IntervalSec = 1
)

# GPU sampler for perf_regression.py (ASCII only: Windows PowerShell 5.1
# reads UTF-8-without-BOM as ANSI, so non-ASCII comments can break parsing).
# Output columns (tab separated):
#   t_ms  gpu_total  gpu_3d  dedicated  shared
# dedicated/shared are bytes. Filter counters by instance "pid_<pid>_".
$sep = [char]9
$sw = [System.Diagnostics.Stopwatch]::StartNew()
"t_ms${sep}gpu_total${sep}gpu_3d${sep}dedicated${sep}shared" |
    Out-File -FilePath $OutFile -Encoding utf8

while ($true) {
    $t = $sw.ElapsedMilliseconds
    $total = 0.0
    $three = 0.0
    $ded = 0.0
    $shr = 0.0
    $matched = $false
    try {
        $samples = (Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage',
            '\GPU Process Memory(*)\Dedicated Usage',
            '\GPU Process Memory(*)\Shared Usage' `
                -ErrorAction SilentlyContinue).CounterSamples
        foreach ($x in $samples) {
            if ($x.InstanceName -notmatch ("pid_" + $TargetPid + "_")) { continue }
            $matched = $true
            if ($x.Path -like '*Utilization Percentage*') {
                $total += $x.CookedValue
                if ($x.InstanceName -like '*engtype_3d*') { $three += $x.CookedValue }
            } elseif ($x.Path -like '*Dedicated Usage*') {
                $ded += $x.CookedValue
            } elseif ($x.Path -like '*Shared Usage*') {
                $shr += $x.CookedValue
            }
        }
    } catch {}
    if (-not $matched) {
        # Counter instance may not exist yet; still emit a zero row so callers
        # can distinguish "no GPU activity" from "sampler never started".
    }
    ("{0}${sep}{1:F2}${sep}{2:F2}${sep}{3:F0}${sep}{4:F0}" -f `
            $t, $total, $three, $ded, $shr) |
        Out-File -FilePath $OutFile -Append -Encoding utf8
    Start-Sleep -Milliseconds (1000 * $IntervalSec)
}
