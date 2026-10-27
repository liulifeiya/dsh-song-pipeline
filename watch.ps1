<#
  E:\_oc_work\watch.ps1  —  song pipeline watchdog
  new audio file lands in watched dir -> auto convert to mp3;
  with -Full it continues: separate -> RVC voice change -> mix
  usage:
    powershell -File E:\_oc_work\watch.ps1                     # resident, mp3 only
    powershell -File E:\_oc_work\watch.ps1 -Full               # resident, full chain
    powershell -File E:\_oc_work\watch.ps1 -ProcessExisting -Once   # process what is there now
#>
param(
  [string[]]$Dirs = @('E:\_oc_work\in', 'C:\Users\28121\Music\VipSongsDownload', 'C:\Users\28121\Music'),
  [int]$PollSec = 3,
  [switch]$Full,
  [switch]$ProcessExisting,
  [switch]$Once
)

$ErrorActionPreference = 'Continue'
$Root      = 'E:\_oc_work'
$Log       = Join-Path $Root 'watch.log'
$StateFile = Join-Path $Root 'watch-state.json'
$OutDir    = Join-Path $Root 'out'
$SepDir    = Join-Path $Root 'sep'
$PySep     = 'D:\AI\RVC\.venv\Scripts\python.exe'   # 必须是有 torch 的那个；Python310 里没装
$SepScript = Join-Path $Root 'uvr5_sep.py'
$CoverPs1  = Join-Path $Root 'cover.ps1'
$RunPs1    = Join-Path $Root 'run.ps1'
$FFmpeg    = Join-Path $Root 'bin\ffmpeg.exe'
$SelfExe   = (Get-Process -Id $PID).Path
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

New-Item -ItemType Directory -Force -Path $OutDir, $SepDir | Out-Null

$EncExt = @('.mgg','.mgg0','.mgg1','.mggl','.mflac','.mflac0','.ncm','.qmc0','.qmc2','.qmc3','.qmcflac','.qmcogg','.bkcmp3','.bkcflac','.tm0','.tm2','.tm3')
$PlainExt = @('.mp3','.flac','.wav','.m4a','.aac','.ogg')

function Write-Log([string]$m) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
  Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

$State = @{}
if (Test-Path $StateFile) {
  try {
    $j = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    if ($j) { foreach ($p in $j.PSObject.Properties) { $State[$p.Name] = [int64]$p.Value } }
  } catch { }
}
function Save-State {
  $o = [ordered]@{}
  foreach ($k in $State.Keys) { $o[$k] = $State[$k] }
  try { ($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
}

function Test-AudioOk([string]$path, [int]$minSec = 30) {
  # 转码"成功"不等于成品可用：OpenConverter 遇到它解不了的 mgg 变体，
  # 会只吐前两秒、却仍返回退出码 0。所以必须查时长，不能只看文件在不在。
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  $ffp = Join-Path $Root 'bin\ffprobe.exe'
  $d = (& $ffp -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $path 2>&1) -join ''
  $sec = 0.0
  if (-not [double]::TryParse(($d -replace '[^\d\.]', ''), [ref]$sec)) { return $false }
  return ($sec -ge $minSec)
}

function Convert-Encrypted([System.IO.FileInfo]$f) {
  $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $mp3  = Join-Path $OutDir ($stem + '.mp3')
  Write-Log "  convert: $($f.Name)"
  $r = & $SelfExe -NoLogo -NoProfile -File $RunPs1 -InputFile $f.FullName 2>&1
  foreach ($l in $r) { Write-Log ('    ' + $l) }
  $cand = $null
  if (Test-Path -LiteralPath $mp3) { $cand = $mp3 }
  else {
    $c = Get-ChildItem -LiteralPath $OutDir -Filter ($stem + '*.mp3') -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($c) { $cand = $c.FullName }
  }
  if ($cand -and (Test-AudioOk $cand)) { return $cand }
  if ($cand) { Write-Log ("  FAILED: 产出的 mp3 时长不足（{0}），是残包 —— 源 mgg 可能是不受支持的变体" -f (Split-Path $cand -Leaf)) }
  return $null
}

function Convert-Plain([System.IO.FileInfo]$f) {
  # 明文音频（ogg/m4a/flac/wav/aac）→ 320k mp3。
  # QQ 音乐下"全部免费"的曲子会给明文 ogg，落在 Music 根目录而不是 VipSongsDownload。
  $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $mp3  = Join-Path $OutDir ($stem + '.mp3')
  Write-Log "  transcode: $($f.Name)"
  $r = & $FFmpeg -y -v error -i $f.FullName -map_metadata -1 -c:a libmp3lame -b:a 320k $mp3 2>&1
  foreach ($l in $r) { if ($l) { Write-Log ('    ' + $l) } }
  if (Test-Path -LiteralPath $mp3) {
    if (Test-AudioOk $mp3) { return $mp3 }
    Write-Log '  FAILED: 转出来的 mp3 时长不足，是残包'
  }
  return $null
}

function Invoke-Full([string]$mp3) {
  $stem = [IO.Path]::GetFileNameWithoutExtension($mp3)
  $sepOut = Join-Path $SepDir $stem
  Write-Log "  separate: $stem"
  $r = & $PySep $SepScript $mp3 $sepOut 2>&1
  foreach ($l in $r) { Write-Log ('    ' + $l) }
  $vocal = Get-ChildItem -LiteralPath (Join-Path $sepOut 'vocals') -Filter '*.wav' -ErrorAction SilentlyContinue | Select-Object -First 1
  $inst  = Get-ChildItem -LiteralPath (Join-Path $sepOut 'instrumental') -Filter '*.wav' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $vocal) { Write-Log '  separate FAILED: no vocal track'; return $null }
  $final = Join-Path $OutDir ($stem + ' (mimo_ds).mp3')
  Write-Log "  rvc + mix -> $final"
  $a = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$CoverPs1,'-Vocal',$vocal.FullName,'-Out',$final)
  if ($inst) { $a += @('-Inst', $inst.FullName) }
  $r = & $SelfExe @a 2>&1
  foreach ($l in $r) { Write-Log ('    ' + $l) }
  if (Test-Path $final) { return $final }
  return $null
}

$pending = @{}
Write-Log ('watch start | dirs=' + ($Dirs -join ' ; ') + " | Full=$Full | ProcessExisting=$ProcessExisting")
$firstScan = $true

while ($true) {
  foreach ($d in $Dirs) {
    if (-not (Test-Path $d)) { continue }
    $files = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
      $ext = $f.Extension.ToLower()
      if (($EncExt -notcontains $ext) -and ($PlainExt -notcontains $ext)) { continue }
      $key = $f.FullName
      if ($State.ContainsKey($key) -and [int64]$State[$key] -eq [int64]$f.Length) { continue }
      if ($firstScan -and (-not $ProcessExisting)) {
        $State[$key] = [int64]$f.Length
        continue
      }
      $stable = $ProcessExisting -and $firstScan
      if ($stable -or ($pending.ContainsKey($key) -and [int64]$pending[$key] -eq [int64]$f.Length)) {
        $pending.Remove($key)
        $State[$key] = [int64]$f.Length
        Save-State
        Write-Log ('NEW: {0}  {1:N1} MB' -f $f.Name, ($f.Length / 1MB))
        $mp3 = $null
        if ($EncExt -contains $ext) {
          $mp3 = Convert-Encrypted $f
        } elseif ($ext -eq '.mp3') {
          $mp3 = $f.FullName
        } else {
          $mp3 = Convert-Plain $f
        }
        if (-not $mp3) { Write-Log '  -> FAILED at convert'; continue }
        Write-Log "  -> mp3 ok: $mp3"
        if ($Full) {
          $final = Invoke-Full $mp3
          if ($final) { Write-Log "  -> FINAL: $final" } else { Write-Log '  -> FAILED at cover' }
        }
      } else {
        $pending[$key] = [int64]$f.Length
      }
    }
  }
  if ($firstScan) { Save-State; $firstScan = $false }
  if ($Once) { break }
  Start-Sleep -Seconds $PollSec
}

