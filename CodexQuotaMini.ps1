# Windows / PowerShell. Run a second time to turn off the indicator.
using namespace System.Windows.Automation
using namespace System.Windows
Add-Type -AssemblyName PresentationFramework,UIAutomationClient,UIAutomationTypes
$newInstance = $false
$stop = [Threading.EventWaitHandle]::new($false, 'AutoReset', 'Local\FrankQuotaMiniStop', [ref]$newInstance)
if (-not $newInstance) { $null = $stop.Set(); $stop.Dispose(); return }

# Only this window gets these styles. Let mouse input reach the original Codex button.
Add-Type -Name Window -Namespace Quota -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int index);
[DllImport("user32.dll")] public static extern int SetWindowLongW(IntPtr h, int index, int value);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attribute, out int value, int size);
'@

function Test-OwnerVisible([IntPtr]$handle) {
    if (-not [Quota.Window]::IsWindowVisible($handle) -or [Quota.Window]::IsIconic($handle) -or
        [Quota.Window]::GetForegroundWindow() -ne $handle) { return $false }
    $cloaked = 0
    $result = [Quota.Window]::DwmGetWindowAttribute($handle,14,[ref]$cloaked,4)
    return $result -eq 0 -and $cloaked -eq 0
}

function Read-WeeklyQuota {
    $ErrorActionPreference = 'Stop'
    $exe = (Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $exe) {
        $exe = Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\bin\*\codex.exe" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    $info = [Diagnostics.ProcessStartInfo]::new($exe, 'app-server --listen stdio://')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $info.RedirectStandardInput = $info.RedirectStandardOutput = $info.RedirectStandardError = $true
    $child = [Diagnostics.Process]::Start($info)
    try {
        $child.BeginErrorReadLine()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        function Reply($id) {
            while ($timer.ElapsedMilliseconds -lt 14000) {
                $read = $child.StandardOutput.ReadLineAsync()
                if (-not $read.Wait([int][Math]::Max(1,14000 - $timer.ElapsedMilliseconds)) -or $null -eq $read.Result) { break }
                $reply = $read.Result | ConvertFrom-Json
                if ($reply.id -eq $id -and -not $reply.method) {
                    if ($reply.error) { throw 'quota unavailable' }
                    return $reply.result
                }
            }
            throw 'quota timed out'
        }
        $child.StandardInput.WriteLine('{"method":"initialize","id":1,"params":{"clientInfo":{"name":"frank_quota_mini","version":"1"}}}')
        $null = Reply 1
        $child.StandardInput.WriteLine('{"method":"initialized"}')
        $child.StandardInput.WriteLine('{"method":"account/rateLimits/read","id":2}')
        $result = Reply 2
        $bucket = $result.rateLimitsByLimitId.codex
        if (-not $bucket -and $result.rateLimits.limitId -in @($null,'codex')) { $bucket = $result.rateLimits }
        foreach ($period in $bucket.primary, $bucket.secondary) {
            if ($period.windowDurationMins -eq 10080 -and $period.usedPercent -is [ValueType] -and
                $period.usedPercent -isnot [bool] -and $period.usedPercent -ge 0 -and $period.usedPercent -le 100) {
                return [pscustomobject]@{ Percent = 100 - $period.usedPercent; Reset = $period.resetsAt }
            }
        }
    } finally {
        $child.StandardInput.Close()
        if (-not $child.WaitForExit(700)) { $child.Kill() }
        $child.Dispose()
    }
}

function Find-Meter($ownerElement) {
    foreach ($name in '使用額度','Usage limits','Usage','用量限额','使用额度') {
        $condition = [PropertyCondition]::new([AutomationElement]::NameProperty, $name)
        $item = $ownerElement.FindFirst([TreeScope]::Descendants, $condition)
        if ($item -and $item.Current.ControlType -eq [ControlType]::Button) { return $item }
    }
}

$window = [Window]::new()
$window.Title = 'Frank 週額度'
$window.WindowStyle = 'None'; $window.ResizeMode = 'NoResize'
$window.AllowsTransparency = $true; $window.Background = 'Transparent'
$window.ShowInTaskbar = $false; $window.ShowActivated = $false
$window.Left = $window.Top = -32000
$window.Width = $window.Height = 36
$label = [Controls.TextBlock]::new()
$label.FontFamily = 'Segoe UI'; $label.FontSize = 14; $label.FontWeight = 'SemiBold'
$number = [Documents.Run]::new('…')
$percentSign = [Documents.Run]::new()
$percentSign.FontSize = 7; $percentSign.FontWeight = 'Normal'
$label.Inlines.Add($number); $label.Inlines.Add($percentSign)
$label.HorizontalAlignment = 'Center'
$light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -ne 0
$track = [Controls.Border]::new()
$track.Width = 24; $track.Height = 2; $track.CornerRadius = [CornerRadius]::new(1)
$track.Margin = [Thickness]::new(0,2,0,0)
$track.Background = if ($light) { '#D8DAD9' } else { '#515552' }
$track.Visibility = 'Collapsed'
$fill = [Controls.Border]::new()
$fill.HorizontalAlignment = 'Left'; $fill.CornerRadius = $track.CornerRadius; $fill.Width = 0
$track.Child = $fill
$stack = [Controls.StackPanel]::new()
$null = $stack.Children.Add($label); $null = $stack.Children.Add($track)
$fit = [Controls.Viewbox]::new()
$fit.StretchDirection = 'DownOnly'; $fit.Child = $stack
$chip = [Controls.Border]::new()
$chip.Child = $fit
$chip.Background = if ($light) { '#F3F3F3' } else { '#272727' }
$label.Foreground = if ($light) { '#252525' } else { '#F2F2F2' }
$window.Content = $chip

$ownerProcess = Get-Process -Name 'ChatGPT','Codex' -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle.ToInt64() -ne 0 -and $_.Path -like '*\WindowsApps\OpenAI.Codex_*\app\*'
} | Select-Object -First 1
if (-not $ownerProcess) {
    $null = [MessageBox]::Show('請先開啟 Codex 主視窗，再開啟額度顯示。', 'Codex 額度')
    $stop.Dispose(); return
}
$owner = [AutomationElement]::FromHandle($ownerProcess.MainWindowHandle)
$ownerHandle = $ownerProcess.MainWindowHandle
$helper = [Interop.WindowInteropHelper]::new($window)
$helper.Owner = $ownerHandle
$hwnd = $helper.EnsureHandle()
$style = [Quota.Window]::GetWindowLongW($hwnd,-20)
$null = [Quota.Window]::SetWindowLongW($hwnd,-20,($style -bor 0x080800A0)) # layered, click-through, toolwindow, no activation

$tick = [Threading.DispatcherTimer]::new()
$tick.Interval = [TimeSpan]::FromMilliseconds(200)
$state = @{ Next = 0; Job = $null; Meter = $null; RetryAnchor = 0; PositionCheck = 0; Rect = $null }
$tick.Add_Tick({
    if ($stop.WaitOne(0) -or $ownerProcess.HasExited -or -not [Quota.Window]::IsWindow($ownerHandle)) {
        $window.Close(); return
    }
    # UI Automation can return stale button bounds after minimize or Show Desktop.
    if (-not (Test-OwnerVisible $ownerHandle)) {
        if ($window.IsVisible) { $window.Hide() }
        $state.Rect = $null; return
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
        if (-not $state.Meter -and $now -ge $state.RetryAnchor) {
            $state.RetryAnchor = $now + 5
            $state.Meter = Find-Meter $owner
        }
        if (-not $state.Meter) { $state.Rect = $null; $window.Hide(); return }
        if (-not $state.Rect -or $now -ge $state.PositionCheck) {
            $state.PositionCheck = $now + 1
            $state.Rect = $state.Meter.Current.BoundingRectangle
        }
        $rect = $state.Rect
        if (-not $rect -or $rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0 -or $state.Meter.Current.IsOffscreen) {
            $state.Meter = $null; $state.Rect = $null; $window.Hide(); return
        }
    } catch { $state.Meter = $null; $state.Rect = $null; $window.Hide(); return }
    # Recheck after UI Automation, which may finish after the user switches windows.
    if (-not (Test-OwnerVisible $ownerHandle)) { $window.Hide(); $state.Rect = $null; return }
    # Cover the original dial, leaving the outer button edge and click target intact.
    $width = $height = [int]([Math]::Min($rect.Width,$rect.Height) * .88)
    $x = [int]($rect.Left + ($rect.Width - $width)/2); $y = [int]($rect.Top + ($rect.Height - $height)/2)
    $null = [Quota.Window]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $width, $height, 0x14)
    if (-not $window.IsVisible) { $window.Show() }
    if ($state.Job -and $state.Job.IsCompleted) {
        try { $data = @($state.Worker.EndInvoke($state.Job)) | Select-Object -First 1 } catch { $data = $null }
        $state.Worker.Dispose(); $state.Job = $null
        $valid = $data -and (-not $data.Reset -or $data.Reset -gt $now)
        $number.Text = if ($valid) { '{0:0.#}' -f $data.Percent } else { '—' }
        $percentSign.Text = if ($valid) { '%' } else { '' }
        $track.Visibility = if ($valid) { 'Visible' } else { 'Collapsed' }
        if ($valid) {
            $fill.Width = $track.Width * $data.Percent / 100
            $fill.Background = if ($data.Percent -le 10) {
                if ($light) { '#AE4B45' } else { '#EF9288' }
            } elseif ($data.Percent -le 20) {
                if ($light) { '#96611F' } else { '#E1B574' }
            } else {
                if ($light) { '#287C6B' } else { '#79CDB7' }
            }
        }
        $state.Next = if ($valid) { $now + 300 } else { $now + 60 }
        if ($valid -and $data.Reset) { $state.Next = [Math]::Min([long]$state.Next,[long]$data.Reset) }
    }
    if (-not $state.Job -and $now -ge $state.Next) {
        $number.Text = '…'; $percentSign.Text = ''; $track.Visibility = 'Collapsed'
        $state.Worker = [PowerShell]::Create()
        $null = $state.Worker.AddScript(${function:Read-WeeklyQuota}.ToString())
        $state.Job = $state.Worker.BeginInvoke()
    }
})
try {
    $tick.Start()
    $app = [Application]::new()
    $null = $app.Run($window)
} finally {
    $tick.Stop()
    if ($state.Worker) { $state.Worker.Dispose() }
    $stop.Dispose()
}
