<#
  E:\_oc_work\selftest.ps1  —  批量自测：跑若干首歌，统计下载成功率

  用法：
      powershell -File E:\_oc_work\selftest.ps1
      powershell -File E:\_oc_work\selftest.ps1 -Songs "晴天","稻香","起风了"
      powershell -File E:\_oc_work\selftest.ps1 -WaitSec 45

  做的事：
      逐首调 fetch.ps1，记录 成功/失败、耗时、落盘文件名、失败原因，
      最后打印汇总表 + 成功率，并写一份报告到 selftest-report.md。
#>
param(
  [string[]]$Songs = @('紅蓮華', 'Pretender', '白日', 'アイドル', '残酷な天使のテーゼ'),
  [int]$WaitSec = 45,
  [int]$GapSec = 3
)

$ErrorActionPreference = 'Continue'
$Root      = 'E:\_oc_work'
$FetchPs1  = Join-Path $Root 'fetch.ps1'
$Report    = Join-Path $Root 'selftest-report.md'
$Log       = Join-Path $Root 'selftest.log'

function Write-Log([string]$m) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
  Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
  Write-Host $line
}

Write-Log "===== 自测开始：$($Songs.Count) 首 ====="
$t0All = Get-Date
$results = @()

$i = 0
foreach ($s in $Songs) {
  $i++
  Write-Log "--- [$i/$($Songs.Count)] $s ---"
  $t0 = Get-Date

  # 每次独立进程跑，避免状态互相污染
  $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
              -File $FetchPs1 -Title $s -WaitSec $WaitSec 2>&1
  $code = $LASTEXITCODE
  $sec  = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

  $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
  $ok   = ($code -eq 0)

  # 落盘文件 = 最后一行非空输出（fetch.ps1 末尾 Write-Output 路径）
  $file = ''
  $lines = ($text -split "`n" | Where-Object { $_.Trim() })
  if ($ok -and $lines.Count -gt 0) { $file = $lines[$lines.Count - 1].Trim() }

  # 失败原因：抓 throw 的那一句
  $err = ''
  if (-not $ok) {
    $m = [regex]::Match($text, '(中止[^\r\n]*|只定位到[^\r\n]*|没弹面板[^\r\n]*|点了下载[^\r\n]*|没能把[^\r\n]*|找不到[^\r\n]*|OCR[^\r\n]*)')
    if ($m.Success) { $err = $m.Value } else { $err = ($lines | Select-Object -Last 1) }
    if ($err.Length -gt 90) { $err = $err.Substring(0, 90) + '…' }
  }

  $fname = ''
  if ($file) { $fname = Split-Path $file -Leaf }
  $results += [pscustomobject]@{
    No     = $i
    Song   = $s
    Ok     = $ok
    Sec    = $sec
    File   = $fname
    Err    = $err
  }

  Write-Log ("  结果: {0}  耗时 {1}s  {2}" -f ($(if ($ok) { '成功' } else { '失败' })), $sec, $file)
  if (-not $ok) { Write-Log "  原因: $err" }

  if ($i -lt $Songs.Count) { Start-Sleep -Seconds $GapSec }
}

$totalSec = [math]::Round(((Get-Date) - $t0All).TotalSeconds, 1)
$okCount  = @($results | Where-Object { $_.Ok }).Count
$rate     = [math]::Round(100.0 * $okCount / $Songs.Count, 1)

Write-Log "===== 自测结束：$okCount/$($Songs.Count) 成功，成功率 $rate%，总耗时 ${totalSec}s ====="

# ---------- 报告 ----------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# song-pipeline · fetch 自测报告')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$sb.AppendLine("结果：**$okCount / $($Songs.Count) 成功（$rate%）**，总耗时 ${totalSec}s")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('| # | 歌名 | 结果 | 耗时 | 落盘文件 / 失败原因 |')
[void]$sb.AppendLine('|---|---|---|---|---|')
foreach ($r in $results) {
  $mark = if ($r.Ok) { '✅' } else { '❌' }
  $detail = if ($r.Ok) { $r.File } else { $r.Err }
  [void]$sb.AppendLine("| $($r.No) | $($r.Song) | $mark | $($r.Sec)s | $detail |")
}
[void]$sb.AppendLine('')
if ($okCount -lt $Songs.Count) {
  [void]$sb.AppendLine('## 失败归类')
  [void]$sb.AppendLine('')
  foreach ($r in ($results | Where-Object { -not $_.Ok })) {
    [void]$sb.AppendLine("- **$($r.Song)**：$($r.Err)")
  }
}
try {
  $sb.ToString() | Set-Content -LiteralPath $Report -Encoding UTF8
  Write-Log "报告已写：$Report"
} catch {
  Write-Log "报告写失败：$($_.Exception.Message)"
}

# 控制台汇总
Write-Host ''
Write-Host ('=' * 64)
Write-Host ("{0,-18} {1,-6} {2,-8} {3}" -f '歌名', '结果', '耗时', '文件/原因')
Write-Host ('-' * 64)
foreach ($r in $results) {
  $mark = if ($r.Ok) { '成功' } else { '失败' }
  $detail = if ($r.Ok) { $r.File } else { $r.Err }
  Write-Host ("{0,-18} {1,-6} {2,-8} {3}" -f $r.Song, $mark, "$($r.Sec)s", $detail)
}
Write-Host ('-' * 64)
Write-Host ("成功率：{0}/{1} = {2}%   总耗时 {3}s" -f $okCount, $Songs.Count, $rate, $totalSec)
Write-Host ('=' * 64)
