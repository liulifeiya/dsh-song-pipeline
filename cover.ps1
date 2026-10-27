param(
  [Parameter(Mandatory=$true)][string]$Vocal,
  [string]$Inst = "",
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Model = "mimo_ds_e200_s8200.pth",
  [int]$Pitch = 0,
  [double]$Hop = 30.0,
  [double]$Ctx = 2.0
)

# 分段过 RVC，再拼回整首 —— 6GB 显存扛不住一次性推整首
$ErrorActionPreference = "Continue"
$work = "E:\_oc_work\cover"
$ff   = "E:\_oc_work\bin\ffmpeg.exe"
$fp   = "E:\_oc_work\bin\ffprobe.exe"
$py   = "D:\AI\RVC\.venv\Scripts\python.exe"

if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$work\chunks", "$work\rvc", "$work\trim" | Out-Null

$dur = [double](& $fp -v error -show_entries format=duration -of csv=p=0 $Vocal)
$n = [int][math]::Ceiling(($dur - 0.5) / $Hop)
Write-Output ("duration={0:N1}s  chunks={1}" -f $dur, $n)

$concat = @()
for ($i = 0; $i -lt $n; $i++) {
  $start = [math]::Max(0, $i * $Hop - $Ctx)
  $len   = [math]::Min($dur - $start, $Hop + 2 * $Ctx)
  $chunk = "$work\chunks\c{0:D3}.wav" -f $i
  & $ff -y -hide_banner -loglevel error -ss $start -t $len -i $Vocal -ar 44100 -ac 2 $chunk

  $rw = "$work\rvc\c{0:D3}.wav" -f $i
  $logPath = "$work\rvc\c{0:D3}.log" -f $i
  Push-Location "D:\AI\RVC"
  & $py -m infer.cli --model $Model --input $chunk --output $rw --format wav `
      --f0-method rmvpe --pitch $Pitch --index-rate 0.75 --overwrite 2> $logPath | Out-Null
  Pop-Location
  if (-not (Test-Path $rw) -or (Get-Item $rw).Length -lt 100KB) {
    Write-Output ("chunk {0} FAILED" -f $i)
    Get-Content $logPath -ErrorAction SilentlyContinue | Select-Object -Last 6
    exit 1
  }

  $head = if ($i -eq 0) { 0 } else { $Ctx }
  $tail = if ($i -eq $n - 1) { 0 } else { $Ctx }
  $keep = [math]::Max(0.5, $len - $head - $tail)
  $tw = "$work\trim\t{0:D3}.wav" -f $i
  & $ff -y -hide_banner -loglevel error -ss $head -t $keep -i $rw -ar 44100 -ac 2 $tw
  $concat += "file '" + ($tw -replace '\\', '/') + "'"
  Write-Output ("chunk {0}/{1} ok  ({2:N1}s)" -f ($i + 1), $n, $keep)
}

$listFile = "$work\list.txt"
$concat -join "`n" | Set-Content -Path $listFile -Encoding ASCII
$vocalFull = "$work\vocal_full.wav"
& $ff -y -hide_banner -loglevel error -f concat -safe 0 -i $listFile -c copy $vocalFull
Write-Output ("vocal_full: {0:N1}s" -f [double](& $fp -v error -show_entries format=duration -of csv=p=0 $vocalFull))

if ($Inst -and (Test-Path $Inst)) {
  & $ff -y -hide_banner -loglevel error -i $vocalFull -i $Inst `
      -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0:weights=1 0.9,alimiter=limit=0.97[a]" `
      -map "[a]" -ar 44100 -b:a 320k $Out
} else {
  & $ff -y -hide_banner -loglevel error -i $vocalFull -b:a 320k $Out
}
Write-Output ("OUT: {0}  {1:N1} MB" -f $Out, ((Get-Item $Out).Length / 1MB))
