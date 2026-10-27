# OpenConverter CLI runner — reads QQ cookie from the app config so the secret
# never appears on the command line.
param([Parameter(Mandatory=$true)][string]$InputFile, [string]$Format = "mp3", [string]$Quality = "320k")

$ErrorActionPreference = "Stop"
$appDir = "E:\_oc_extract\app_asar"
$work   = "E:\_oc_work"
$cfgPath = Join-Path $env:APPDATA "OpenConverter\openconverter-config.json"

$node = "C:\Program Files\nodejs\node.exe"
$env:PATH = "$work\bin;" + $env:PATH

$args = @("src\cli.js", "--format=$Format", "--quality=$Quality", "--output-dir=$work\out")
if (Test-Path $cfgPath) {
  $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
  if ($cfg.qqCookie) { $args += "--qq-cookie=$($cfg.qqCookie)" }
  if ($cfg.qmcEkey)  { $args += "--ekey=$($cfg.qmcEkey)" }
  if ($cfg.ncmLyricsDir -and (Test-Path $cfg.ncmLyricsDir)) { $args += "--ncm-lyrics-dir=$($cfg.ncmLyricsDir)" }
}
$args += $InputFile

Push-Location $appDir
try {
  & $node @args
  $code = $LASTEXITCODE
} finally { Pop-Location }
exit $code
