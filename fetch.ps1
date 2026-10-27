<#
  E:\_oc_work\fetch.ps1  —  song-pipeline 的上游：按歌名去 QQ 音乐取歌

  这是整条链的第一环：
      歌名 --> 搜索 --> 选结果行 --> 点下载 --> 落盘 --> （watch.ps1 接手转 mp3）

  用法：
      powershell -File E:\_oc_work\fetch.ps1 -Title "威风堂堂"
      powershell -File E:\_oc_work\fetch.ps1 -Title "威风堂堂" -Row 2      # 下第 2 条结果
      powershell -File E:\_oc_work\fetch.ps1 -Title "威风堂堂" -Full        # 下完直接跑分离+RVC

  说明：
    · 只能下"全部免费"或"会员可下"的曲子。需要单独付费/下载券的，点了也不落盘，
      脚本会如实报"点了但没落盘"，不会假装成功。
    · 只做界面点击，不碰接口/签名。
#>
param(
  [Parameter(Mandatory=$true)][string]$Title,
  [int]$Row = 1,
  [switch]$Full,
  [int]$WaitSec = 90,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root      = 'E:\_oc_work'
$Log       = Join-Path $Root 'fetch.log'
$ShotDir   = Join-Path $Root 'tmp'
$QqExe     = 'E:\HRSoftstore\Install\qqyinyue\QQMusic\QQMusic.exe'
$WatchPs1  = Join-Path $Root 'watch.ps1'
$PlainDir  = 'C:\Users\28121\Music'
$VipDir    = Join-Path $PlainDir 'VipSongsDownload'
$StateFile = Join-Path $Root 'fetch-state.json'

New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null

function Write-Log([string]$m) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
  Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
  Write-Host $line
}

# ---------- Win32 ----------
Add-Type @"
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public class WE {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  public struct RECT { public int L,T,R,B; }
  // 返回 "hWnd;class;L,T,R,B;WxH;vis;title"
  // 不过滤 ——— 主窗口最小化时也得能列出来（才能恢复它）。
  // 但把可见性一起返回，让调用方自己决定：找面板必须只用可见的。
  public static List<string> List(uint wanted) {
    var res = new List<string>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != wanted) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      int w = r.R - r.L, hh = r.B - r.T;
      var sb = new StringBuilder(256); GetClassName(h, sb, 256);
      var tb = new StringBuilder(512); GetWindowText(h, tb, 512);
      res.Add(h.ToInt64() + ";" + sb + ";" + r.L + "," + r.T + "," + r.R + "," + r.B + ";" + w + "x" + hh + ";" + IsWindowVisible(h) + ";" + tb);
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class QF {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk,byte sc,uint f,UIntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L,T,R,B; }
}
"@

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FG {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);

  // 后台进程直接 SetForegroundWindow 会被 Windows 的前台锁拒绝。
  // 两条路依次试：先敲一下 ALT 解除锁定，再 AttachThreadInput 挂到前台线程上。
  public static bool Force(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    ShowWindow(h, 9);
    System.Threading.Thread.Sleep(150);
    keybd_event(0x12, 0, 0, UIntPtr.Zero);
    keybd_event(0x12, 0, 2, UIntPtr.Zero);
    SetForegroundWindow(h);
    if (GetForegroundWindow() == h) return true;

    uint dummy;
    uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out dummy);
    uint myThread = GetCurrentThreadId();
    AttachThreadInput(myThread, fgThread, true);
    BringWindowToTop(h);
    SetActiveWindow(h);
    SetForegroundWindow(h);
    AttachThreadInput(myThread, fgThread, false);
    return GetForegroundWindow() == h;
  }
}
"@

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class GX {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x,int y,int cx,int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT{public int L,T,R,B;}
}
"@

function Fix-Window($w, [int]$x = 0, [int]$y = 0, [int]$cw = 1226, [int]$ch = 800) {
  # 恢复 → 挪到固定位置、固定尺寸。之后所有坐标都是绝对的，不用按比例换算。
  # 顺序不能反：最小化状态下 SetWindowPos 改的是占位矩形，不生效。
  # 而且设完之后窗口可能又被最小化（人在动电脑），所以必须校验，不对就重试。
  $rr = New-Object GX+RECT
  for ($try = 1; $try -le 4; $try++) {
    [GX]::ShowWindow($w.Handle, 9) | Out-Null
    Start-Sleep -Milliseconds 500
    [void][GX]::SetWindowPos($w.Handle, [IntPtr]::Zero, $x, $y, $cw, $ch, 0x14)
    Start-Sleep -Milliseconds 500
    [GX]::GetWindowRect($w.Handle, [ref]$rr) | Out-Null
    $cwNow = $rr.R - $rr.L; $chNow = $rr.B - $rr.T
    if ($cwNow -eq $cw -and $chNow -eq $ch -and $rr.L -eq $x -and $rr.T -eq $y) {
      Write-Log "窗口已钉好 $x,$y ${cw}x${ch}（第 $try 次尝试）"
      return [pscustomobject]@{ L = $rr.L; T = $rr.T; R = $rr.R; B = $rr.B }
    }
    Write-Log ("窗口没钉住（当前 {0}x{1} @{2},{3}），重试 {4}/4" -f $cwNow, $chNow, $rr.L, $rr.T, $try)
    Start-Sleep -Milliseconds 700
  }
  throw "窗口钉不住：4 次都失败。可能 QQ 音乐在弹模态框，或被别的程序锁住。"
}

function Get-TitleRows([string]$shotPath, [int]$imgH) {
  # 定位"每一行"：不认文字 —— 文字会被叠加层/hover 高亮压暗，第一行会漏掉（踩过）。
  # 改认每行左侧的封面缩略图：x=262..305，约 40px 高，是彩色块，
  # 跟纯色背景差异明显，且每行都有、行间没有。所以"有封面的连续 y 段"就是一行。
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::FromFile($shotPath)
  try {
    # 背景基准：取列表最左侧空白列 x=240 的平均色
    $bgR = 0.0; $bgG = 0.0; $bgB = 0.0; $n = 0
    for ($y = 300; $y -lt [math]::Min(650, $bmp.Height); $y += 7) {
      $c = $bmp.GetPixel(240, $y)
      $bgR += $c.R; $bgG += $c.G; $bgB += $c.B; $n++
    }
    if ($n -eq 0) { return @() }
    $bgR /= $n; $bgG /= $n; $bgB /= $n

    $rows = New-Object System.Collections.ArrayList
    $inR = $false; $s = 0
    $yEnd = [math]::Min(($imgH - 110), $bmp.Height)
    $xS = 262; $xE = [math]::Min(305, $bmp.Width)
    for ($y = 300; $y -lt $yEnd; $y++) {
      $cnt = 0
      for ($x = $xS; $x -lt $xE; $x += 2) {
        $c = $bmp.GetPixel($x, $y)
        $d = [math]::Abs($c.R - $bgR) + [math]::Abs($c.G - $bgG) + [math]::Abs($c.B - $bgB)
        if ($d -gt 40) { $cnt++ }
      }
      $on = $cnt -ge 4
      if ($on -and -not $inR) { $s = $y; $inR = $true }
      elseif (-not $on -and $inR) {
        # 封面高约 40px。<25 的是表头「歌名/歌手」或底部残渣，丢掉。
        if (($y - $s) -ge 25) { [void]$rows.Add([int](($s + $y - 1) / 2)) }
        $inR = $false
      }
    }
    if ($inR -and (($yEnd - $s) -ge 25)) { [void]$rows.Add([int](($s + $yEnd - 1) / 2)) }
    return $rows
  } finally { $bmp.Dispose() }
}

function Get-RowCenters([string]$shotPath, [int]$imgH) {
  # 结果列表背景是纯色、行之间没有分隔线，但每行有文字。
  # 所以：以"偏离背景色的像素数"为判据，连续有内容的 y 段就是一行。
  # 这样不用猜行高（实测行高在 34~56 之间跳）。
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::FromFile($shotPath)
  try {
    $probeY = 290
    $sr = 0.0; $sg = 0.0; $sb = 0.0; $n = 0
    for ($x = 300; $x -lt 900; $x += 8) {
      if ($x -ge $bmp.Width -or $probeY -ge $bmp.Height) { continue }
      $c = $bmp.GetPixel($x, $probeY)
      $sr += $c.R; $sg += $c.G; $sb += $c.B; $n++
    }
    if ($n -eq 0) { return @() }
    $br = $sr / $n; $bgc = $sg / $n; $bb = $sb / $n

    $tol = 14
    $segs = New-Object System.Collections.ArrayList
    $inRow = $false; $s = 0
    $yEnd = [math]::Min(($imgH - 110), $bmp.Height)
    $xEnd = [math]::Min(900, $bmp.Width)
    for ($y = 300; $y -lt $yEnd; $y++) {
      $cnt = 0
      for ($x = 300; $x -lt $xEnd; $x += 2) {
        $c = $bmp.GetPixel($x, $y)
        if ([math]::Abs($c.R - $br) -gt $tol -or [math]::Abs($c.G - $bgc) -gt $tol -or [math]::Abs($c.B - $bb) -gt $tol) { $cnt++ }
      }
      $on = $cnt -gt 1
      if ($on -and -not $inRow) { $s = $y; $inRow = $true }
      elseif (-not $on -and $inRow) {
        if (($y - $s) -ge 6) { [void]$segs.Add(@{ From = $s; To = $y - 1 }) }
        $inRow = $false
      }
    }
    if ($inRow -and (($yEnd - $s) -ge 6)) { [void]$segs.Add(@{ From = $s; To = $yEnd - 1 }) }

    # 同一行的歌名和歌手之间会有一小段空白（实测 19px），会被切成两段。
    # 间隔小于 22px 的相邻段合并回一行。
    $merged = New-Object System.Collections.ArrayList
    foreach ($g in $segs) {
      if ($merged.Count -gt 0) {
        $last = $merged[$merged.Count - 1]
        if (($g.From - $last.To) -lt 22) { $last.To = $g.To; continue }
      }
      [void]$merged.Add(@{ From = $g.From; To = $g.To })
    }
    $rows = @()
    foreach ($m in $merged) { $rows += [int](($m.From + $m.To) / 2) }
    return $rows
  } finally { $bmp.Dispose() }
}

function Get-QqWindow {
  $p = Get-Process QQMusic -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $p) {
    Write-Log 'QQ 音乐没在跑，启动它'
    if (-not (Test-Path $QqExe)) { throw "找不到 QQMusic.exe: $QqExe" }
    Start-Process -FilePath $QqExe | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Milliseconds 800
      $p = Get-Process QQMusic -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($p) { break }
    }
    if (-not $p) { throw 'QQ 音乐启动后没拿到进程' }
    Start-Sleep -Seconds 4
  }
  # 主窗口靠标题认：title=[QQ音乐]。
  # 不能用"面积最大"—— 主窗口最小化时面积只剩 160x28，会被 490x381 的对话框比下去，
  # 于是脚本抓着对话框去点，全程都在对错的目标操作（踩过）。
  for ($i = 0; $i -lt 20; $i++) {
    foreach ($ln in [WE]::List([uint32]$p.Id)) {
      $parts = $ln -split ';', 6
      if ($parts.Count -lt 6) { continue }
      if ($parts[1] -ne 'TXGuiFoundation') { continue }
      if ($parts[5] -ne 'QQ音乐') { continue }
      $wh = $parts[3] -split 'x'
      return [pscustomobject]@{
        Handle = [IntPtr][int64]$parts[0]
        Id     = $p.Id
        W      = [int]$wh[0]
        H      = [int]$wh[1]
        Title  = $parts[5]
      }
    }
    Start-Sleep -Milliseconds 500
  }
  throw '找不到 QQ 音乐主窗口（title=QQ音乐 的 TXGuiFoundation）'
}

function Get-Popup([IntPtr]$mainHandle) {
  # 除主窗口外面积最大的那个 TXGuiFoundation 窗口 = 下载面板。
  # 不写死尺寸，面板会因音质选项多少而变高。
  $p = Get-Process QQMusic -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $p) { return $null }
  $best = $null; $bestArea = 0
  foreach ($ln in [WE]::List([uint32]$p.Id)) {
    $parts = $ln -split ';', 6
    if ($parts.Count -lt 6) { continue }
    if ($parts[1] -ne 'TXGuiFoundation') { continue }
    # 只要可见的 —— 进程里有一堆隐藏的辅助窗口（480x605 那种），
    # 不过滤的话"面积最大"会挑中它们，于是点到一个不存在的面板上（踩过）。
    if ($parts[4] -ne 'True') { continue }
    if ([IntPtr]::new([int64]$parts[0]) -eq $mainHandle) { continue }
    $wh = $parts[3] -split 'x'
    $area = [int]$wh[0] * [int]$wh[1]
    if ($area -gt $bestArea) {
      $bestArea = $area
      $rc = $parts[2] -split ','
      $best = [pscustomobject]@{
        L = [int]$rc[0]; T = [int]$rc[1]; R = [int]$rc[2]; B = [int]$rc[3]
        W = [int]$wh[0]; H = [int]$wh[1]
      }
    }
  }
  return $best
}

function Focus-Qq($w) {
  $ok = [FG]::Force($w.Handle)
  Start-Sleep -Milliseconds 700
  if (-not $ok -and [FG]::GetForegroundWindow() -ne $w.Handle) {
    throw '没能把 QQ 音乐切到前台。手动点一下 QQ 音乐窗口再跑，或者等它自己弹出来。'
  }
}

function Click-At([int]$x, [int]$y) {
  [QF]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 220
  [QF]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [QF]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
}

function Move-To([int]$x, [int]$y) {
  [QF]::SetCursorPos($x, $y) | Out-Null
}

function Get-MaxChannel([int]$x, [int]$y, [int]$r = 12) {
  # 取 (x,y) 周围 r 像素见方里最亮的通道值。
  # 用来区分"下载箭头是白色可点"还是"灰色禁用"—— 不靠认图，靠像素。
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap(($r * 2), ($r * 2))
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(($x - $r), ($y - $r), 0, 0, $bmp.Size)
  $max = 0
  for ($i = 0; $i -lt $bmp.Width; $i++) {
    for ($j = 0; $j -lt $bmp.Height; $j++) {
      $c = $bmp.GetPixel($i, $j)
      $v = [Math]::Max($c.R, [Math]::Max($c.G, $c.B))
      if ($v -gt $max) { $max = $v }
    }
  }
  $g.Dispose(); $bmp.Dispose()
  return $max
}

function Send-Ctrl([byte]$vk) {
  [QF]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [QF]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
  [QF]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [QF]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
}

function Send-Enter {
  [QF]::keybd_event(0x0D, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [QF]::keybd_event(0x0D, 0, 2, [UIntPtr]::Zero)
}

function Save-Shot([string]$path, $w) {
  Add-Type -AssemblyName System.Drawing
  $r = New-Object QF+RECT
  [QF]::GetWindowRect($w.Handle, [ref]$r) | Out-Null
  $bw = $r.R - $r.L; $bh = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap($bw, $bh)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  return @{ W = $bw; H = $bh }
}

# ---------- OCR ----------
$script:OcrReady = $false
function Init-Ocr {
  if ($script:OcrReady) { return }
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $script:AsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
  [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
  [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
  $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if (-not $script:OcrEngine) { throw 'OCR 引擎不可用（系统没装中文识别语言包）' }
  $script:OcrReady = $true
}

function Await($op, [Type]$t) {
  $m = $script:AsTask.MakeGenericMethod($t)
  $task = $m.Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  return $task.Result
}

function Read-Shot([string]$path) {
  Init-Ocr
  $sf = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
  $st = Await ($sf.OpenAsync(0)) ([Windows.Storage.Streams.IRandomAccessStream])
  $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($st)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $res = Await ($script:OcrEngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
  $out = @()
  foreach ($ln in $res.Lines) { $out += $ln.Text }
  return $out
}

function Normalize([string]$s) {
  if (-not $s) { return '' }
  return ($s -replace '[\s\-_（）()\[\]【】·,，.。:：!！?？"“”]', '').ToLower()
}

function Similar([string]$a, [string]$b) {
  $a = Normalize $a; $b = Normalize $b
  if (-not $a -or -not $b) { return 0.0 }
  $hit = 0
  foreach ($ch in $a.ToCharArray()) { if ($b.Contains($ch)) { $hit++ } }
  return [double]$hit / [double]$a.Length
}

# ---------- 台账：记下"这个词下过什么"，不靠认界面 ----------
function Load-State {
  $o = @{}
  if (Test-Path $StateFile) {
    try {
      $j = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j) { foreach ($p in $j.PSObject.Properties) { $o[$p.Name] = @($p.Value) } }
    } catch {
      Write-Log "台账读不动，当作空的：$StateFile"
    }
  }
  return $o
}

function Save-State($st) {
  $o = [ordered]@{}
  foreach ($k in $st.Keys) { $o[$k] = @($st[$k]) }
  try {
    ($o | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StateFile -Encoding UTF8
  } catch {
    Write-Log "台账写不进去（不影响本次下载）：$($_.Exception.Message)"
  }
}

function Find-Done($state, [string]$key, [int]$row) {
  foreach ($r in @($state[$key])) {
    if (-not $r) { continue }
    if ([int]$r.row -ne $row) { continue }
    if ($r.file -and (Test-Path -LiteralPath $r.file)) { return $r }
    # 源文件被清掉了（QQ 音乐那边可能还认为"已下载"，箭头是灰的），
    # 但成品 mp3 还在 out 里 —— 那就把它当成品返回，不要去重下。
    if ($r.file) {
      $stem = [IO.Path]::GetFileNameWithoutExtension($r.file)
      $mp3 = Join-Path (Join-Path $Root 'out') ($stem + '.mp3')
      if (Test-Path -LiteralPath $mp3) {
        return [pscustomobject]@{
          row = $r.row; title = $r.title; file = $mp3; at = $r.at
          note = '源文件已不在，返回成品 mp3'
        }
      }
    }
  }
  return $null
}

function Snap-Dir([string]$d) {
  $set = @{}
  if (Test-Path $d) {
    Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
      ForEach-Object { $set[$_.FullName] = [int64]$_.Length }
  }
  return $set
}

function Find-NewFile($before) {
  foreach ($d in @($VipDir, $PlainDir)) {
    if (-not (Test-Path $d)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
      if ($before[$f.FullName] -ne [int64]$f.Length) { return $f }
    }
  }
  return $null
}

# ================= 主流程 =================
Write-Log "===== fetch: $Title (Row=$Row, Full=$Full) ====="

# 先查台账：这个词 + 这个行号是不是已经下过、文件还在。
$state  = Load-State
$stateKey = Normalize $Title
if (-not $Force) {
  $done = Find-Done $state $stateKey $Row
  if ($done) {
    Write-Log ("已下过，跳过：{0}" -f $done.file)
    Write-Log ("  记录于 {0}，标题 [{1}]" -f $done.at, $done.title)
    Write-Log '  （要强制重下加 -Force）'
    Write-Output $done.file
    return
  }
}

$proc = Get-QqWindow
Focus-Qq $proc

# 钉到固定位置 + 固定尺寸，之后坐标都是绝对的
$r = Fix-Window $proc
$W = $r.R - $r.L; $H = $r.B - $r.T
if ($W -lt 800 -or $H -lt 600) { throw "QQ 音乐窗口太小 ($W x $H)，请先恢复正常大小" }
Write-Log "窗口 $($r.L),$($r.T)  ${W}x${H}"

# 几何比例（以 1226x800 实测为基准）
$px = { param($rx) [int]($r.L + $rx * $W) }
$py = { param($ry) [int]($r.T + $ry * $H) }

# --- 1. 搜索 ---
$searchX = & $px 0.3197
$searchY = & $py 0.0513
Click-At $searchX $searchY
Start-Sleep -Milliseconds 700
Set-Clipboard -Value $Title
Start-Sleep -Milliseconds 250
Send-Ctrl 0x41      # Ctrl+A 清掉旧关键词
Start-Sleep -Milliseconds 250
Send-Ctrl 0x56      # Ctrl+V
Start-Sleep -Milliseconds 600
Send-Enter
Write-Log "已搜索：$Title，等结果渲染"
Start-Sleep -Seconds 4

# --- 2. 截图 + OCR 确认 ---
$shot = Join-Path $ShotDir ("fetch_{0}.png" -f (Get-Date -Format 'HHmmss'))
Save-Shot $shot $proc | Out-Null
$texts = Read-Shot $shot
if (-not $texts -or $texts.Count -eq 0) { throw "截图 OCR 没读到任何文本：$shot" }

$joined = ($texts -join ' ')
Write-Log ("OCR 读到 {0} 行文本" -f $texts.Count)

# 结果页右上一定有「找到 N 首歌曲」。没有这行 = 无结果页 / 页面没加载完。
# OCR 会把数字认错（1000 → 1m0），所以只认"找到"两个字，不校验数字。
if ($joined -notmatch '找\s*到') {
  Write-Log '没看到「找到」，判断为无结果页或页面未就绪。一下都不点。'
  foreach ($t in $texts) { Write-Log ('    ' + $t) }
  throw "中止：结果页没有结果计数，点下去会下到推荐内容。截图：$shot"
}

# 找出"最像歌名"的那几行：含目标关键词 或 拉丁字母占比高
$cands = @()
$kwLen = (Normalize $Title).Length
foreach ($t in $texts) {
  # 搜索框显示的就是关键词本身，跟目标必然 100% 相似 —— 排掉。
  if ($t -match '搜\s*索') { continue }
  $sim = Similar $Title $t
  $tl  = (Normalize $t).Length
  # 第二条更狠：sim 极高且长度没比关键词多出多少的，是搜索框或搜索建议，
  # 不是搜索结果行。真歌名通常带歌手/版本/译名，会比关键词长一截。
  if ($sim -ge 0.99 -and $tl -le [math]::Ceiling($kwLen * 1.2)) { continue }
  if ($sim -ge 0.5) { $cands += [pscustomobject]@{ Text = $t; Sim = $sim } }
}
$cands = $cands | Sort-Object Sim -Descending
if ($cands.Count -gt 0) {
  $best = $cands[0]
  Write-Log ("OCR 最佳匹配 sim={0:N2}  [{1}]（仅供参考，不阻断）" -f $best.Sim, $best.Text)
} else {
  # 日文假名 OCR 经常认错（夜に駆ける → 夜仁躯叶），歌名对不上是常态。
  # 按"就下第一个结果"的约定，这里不拦 —— 交给后面的下载箭头亮度检查兜底。
  $best = [pscustomobject]@{ Text = '(OCR 未识别)'; Sim = 0 }
  Write-Log 'OCR 没认出歌名（日文假名常认错），按「下第一个」继续'
}

# --- 3. 定位到歌名：扫白色文字，拿到每首歌名真实的 y ---
$rowShot = Join-Path $ShotDir 'fetch_rows.png'
Move-To ($r.L + 1100) ($r.T + 760)   # 鼠标挪到右下角，否则 hover 高亮会压暗第一行的白字
Start-Sleep -Milliseconds 600
Save-Shot $rowShot $proc | Out-Null
$rowCenters = Get-TitleRows $rowShot $H
Write-Log ("定位到 {0} 首歌名，y = [{1}]" -f $rowCenters.Count, ($rowCenters -join ', '))
if ($rowCenters.Count -lt $Row) {
  throw ("只定位到 {0} 首歌名，不够第 {1} 首。截图：{2}" -f $rowCenters.Count, $Row, $rowShot)
}
$rowY = $r.T + $rowCenters[$Row - 1]
$arrowX = & $px 0.5424
Write-Log ("目标：第 {0} 首歌名，y={1}，点它的下载箭头 ({2},{3})" -f $Row, $rowCenters[$Row - 1], $arrowX, $rowY)

# 文件快照必须在这里拍 —— 在点下载之前。
# 之前的写法是在点完「下载」之后才拍，结果刚落盘的文件被算进"原有文件"，
# 于是轮询永远找不到"新文件"，明明下成功了却报失败（踩过）。
$before = Snap-Dir $VipDir
$before2 = Snap-Dir $PlainDir
foreach ($k in $before2.Keys) { $before[$k] = $before2[$k] }
Move-To ($arrowX) $rowY
Start-Sleep -Milliseconds 900
$arrowBright = Get-MaxChannel $arrowX $rowY 12
Write-Log ("下载箭头区域最亮 {0}（<200 一般是灰的 = 已下载或不可下）" -f $arrowBright)
Click-At $arrowX $rowY
Write-Log "点第 $Row 行的下载箭头 (屏幕 $arrowX,$rowY)"
Start-Sleep -Seconds 2

# --- 4. 下载面板：点底部左侧「会员下载」 ---
$pop = $null
for ($i = 0; $i -lt 12; $i++) {
  $pop = Get-Popup $proc.Handle
  if ($pop) { break }
  Start-Sleep -Milliseconds 400
}
if (-not $pop) {
  Save-Shot (Join-Path $ShotDir 'fetch_nopanel.png') $proc | Out-Null
  if ($arrowBright -lt 200) {
    throw ("没弹面板，而且下载箭头本来就是灰的（区域最亮 {0}）。这首多半已经下载过、或者没有下载权限。别用 -Force 硬试。截图：{1}\fetch_nopanel.png" -f $arrowBright, $ShotDir)
  }
  throw ("点了下载箭头但没弹出下载面板（箭头区域最亮 {0}）。截图：{1}\fetch_nopanel.png" -f $arrowBright, $ShotDir)
}
Write-Log ("下载面板 {0}x{1} @ {2},{3}" -f $pop.W, $pop.H, $pop.L, $pop.T)
Save-Shot (Join-Path $ShotDir 'fetch_panel.png') $proc | Out-Null

# 品质默认就是「标准品质」，不用选。底部左半边是确认按钮（文字可能是「下载」或「会员下载」），
# 右半边是「歌曲下载券」。
# 注意：不能用高度比例 —— 面板高度随音质选项数量变（实测 198 / 294 / 326），
# 但底部按钮栏的高度是固定的。所以按钮位置按"距面板底边固定像素"算。
$btnX = [int]($pop.L + 0.190 * $pop.W)
$btnY = [int]($pop.B - 48)
Click-At $btnX $btnY
Write-Log "点『会员下载』(屏幕 $btnX,$btnY)"
Start-Sleep -Seconds 1

# --- 5. 等落盘 ---
# $before 已在步骤 3 末尾拍好（必须在点击之前）

$newFile = $null
$deadline = (Get-Date).AddSeconds($WaitSec)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 3
  $newFile = Find-NewFile $before
  if ($newFile -and $newFile.Length -gt 0 -and $newFile.LastWriteTime -gt (Get-Date).AddSeconds(-$WaitSec)) { break }
  $newFile = $null
}

if (-not $newFile) {
  Save-Shot (Join-Path $ShotDir 'fetch_timeout.png') $proc | Out-Null
  throw "点了下载，但 $WaitSec 秒内没有文件落盘。可能是：这首需要下载券/单独付费、或下载被拦。截图：$ShotDir\fetch_timeout.png"
}

Write-Log ("落盘：{0}  {1:N2} MB" -f $newFile.FullName, ($newFile.Length / 1MB))

# --- 6. 交给流水线 ---
if ($Full) {
  Write-Log '交给 watch.ps1 跑完整套（分离 → RVC → 混音）'
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $WatchPs1 -ProcessExisting -Once -Full
} else {
  Write-Log 'watcher 在监听这两个目录，会自动转 mp3'
}

Write-Log "===== fetch 完成：$($newFile.Name) ====="

# 记台账：关键词 + 行号 → 落盘文件。下次同一个词直接返回，不再碰界面。
$rec = [pscustomobject]@{
  row   = $Row
  title = $best.Text
  file  = $newFile.FullName
  at    = (Get-Date).ToString('s')
}
$state[$stateKey] = @(@($state[$stateKey]) | Where-Object { $_ }) + $rec
Save-State $state
Write-Log ("台账已记：{0} → {1}" -f $stateKey, $newFile.Name)

Write-Output $newFile.FullName
