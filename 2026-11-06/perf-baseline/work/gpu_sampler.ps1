param(
  [Parameter(Mandatory=$true)][int]$TargetPid,
  [Parameter(Mandatory=$true)][string]$OutFile
)
$sep = [char]9
$sw = [System.Diagnostics.Stopwatch]::StartNew()
"t_ms${sep}gpu_total${sep}gpu_3d${sep}dedicated${sep}shared" | Out-File -FilePath $OutFile -Encoding utf8
while ($true) {
  $t = $sw.ElapsedMilliseconds
  $total = 0.0; $three = 0.0; $ded = 0.0; $shr = 0.0
  try {
    $s = (Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage','\GPU Process Memory(*)\Dedicated Usage','\GPU Process Memory(*)\Shared Usage' -ErrorAction SilentlyContinue).CounterSamples
    foreach ($x in $s) {
      $inst = $x.InstanceName
      if ($inst -notmatch ("pid_" + $TargetPid + "_")) { continue }
      if ($x.Path -like '*Utilization Percentage*') {
        $total += $x.CookedValue
        if ($inst -like '*engtype_3d*') { $three += $x.CookedValue }
      } elseif ($x.Path -like '*Dedicated Usage*') {
        $ded += $x.CookedValue
      } elseif ($x.Path -like '*Shared Usage*') {
        $shr += $x.CookedValue
      }
    }
  } catch {}
  ("{0}${sep}{1:N2}${sep}{2:N2}${sep}{3:N0}${sep}{4:N0}" -f $t,$total,$three,$ded,$shr) | Out-File -FilePath $OutFile -Append -Encoding utf8
  Start-Sleep -Milliseconds 1000
}
