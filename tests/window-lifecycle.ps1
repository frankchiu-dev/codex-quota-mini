param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '../CodexQuotaMini.ps1')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,UIAutomationClient,UIAutomationTypes
Add-Type -Name Native -Namespace QuotaTest -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
public struct Bounds { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Bounds bounds);
'@
$errors = @()
$syntax = [Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $ScriptPath), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join [Environment]::NewLine) }
$source = [IO.File]::ReadAllText((Resolve-Path $ScriptPath))
$fixture = [Windows.Window]::new()
$fixture.Title = 'Quota visibility test'
$fixture.Width = 360; $fixture.Height = 180
$fixture.Left = -24000; $fixture.Top = -24000
$fixture.Show()
$fixtureHandle = [Windows.Interop.WindowInteropHelper]::new($fixture).Handle
$script:fixtureForeground = $fixtureHandle

# Deliberately retain a visible UIA button after its parent is hidden.
# This reproduces stale accessibility information without using the user's Codex UI.
$cachedButton = [pscustomobject]@{ Current = [pscustomobject]@{
    BoundingRectangle = [Windows.Rect]::new(-23960,-23950,40,40)
    IsOffscreen = $false
}}
$read = $syntax.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-WeeklyQuota'
}, $true)
$source = $source.Replace($read.Extent.Text,
    'function Read-WeeklyQuota { [pscustomobject]@{Percent=64;Reset=4102444800} }')
$find = $syntax.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-Meter'
}, $true)
$source = $source.Replace($find.Extent.Text,'function Find-Meter($unused) { return $cachedButton }')
$selection = $source.IndexOf('$ownerProcess = Get-Process')
$selectionEnd = $source.IndexOf('$owner = [AutomationElement]::FromHandle', $selection)
if ($selection -lt 0 -or $selectionEnd -le $selection) { throw 'Owner setup not found' }
$source = $source.Substring(0,$selection) +
    '$ownerProcess = [pscustomobject]@{MainWindowHandle=$fixtureHandle;HasExited=$false}' +
    [Environment]::NewLine + $source.Substring($selectionEnd)
$source = $source.Replace('Local\FrankQuotaMiniStop', 'Local\QuotaTest-' + [guid]::NewGuid())
$source = $source.Replace('-Namespace Quota ', '-Namespace QuotaTest ')
$source = $source.Replace('[Quota.Window]', '[QuotaTest.Window]')
# Supply foreground state deterministically while testing real WPF/native visibility.
# This avoids taking focus away from the user's desktop during regression tests.
$source = $source.Replace('[QuotaTest.Window]::GetForegroundWindow()', '$script:fixtureForeground')

$results = [Collections.Generic.List[object]]::new()
$testState = @{ Step = 0 }
function Check-Display($scenario, $expected) {
    $actual = $window.IsVisible -and [QuotaTest.Native]::IsWindowVisible($hwnd)
    $positioned = $true
    if ($actual -and $expected) {
        $bounds = [QuotaTest.Native+Bounds]::new()
        $null = [QuotaTest.Native]::GetWindowRect($hwnd,[ref]$bounds)
        $button = $cachedButton.Current.BoundingRectangle
        $positioned = $bounds.Left -ge $button.Left -and $bounds.Top -ge $button.Top -and
            $bounds.Right -le $button.Right -and $bounds.Bottom -le $button.Bottom
    }
    $results.Add([pscustomobject]@{
        scenario=$scenario;expected=$expected;actual=$actual;positioned=$positioned
        passed=($actual -eq $expected -and $positioned)
    })
}
$checks = [Windows.Threading.DispatcherTimer]::new()
$checks.Interval = [TimeSpan]::FromMilliseconds(1400)
$checks.Add_Tick({
    switch ($testState.Step) {
        0 {
            $script:fixtureForeground = $fixtureHandle
        }
        1 {
            Check-Display 'owner in foreground' $true
            $script:fixtureForeground = [IntPtr]::Zero
        }
        2 {
            Check-Display 'another app in foreground' $false
            $fixture.WindowState = 'Minimized'
            $window.Hide()
        }
        3 {
            Check-Display 'minimized owner with stale button' $false
            $fixture.WindowState = 'Normal'
            $script:fixtureForeground = $fixtureHandle
        }
        4 {
            Check-Display 'restored owner' $true
            $fixture.Hide()
            $window.Hide()
        }
        5 {
            Check-Display 'hidden owner with stale button' $false
            $fixture.Show()
            $script:fixtureForeground = $fixtureHandle
        }
        6 {
            Check-Display 'shown again' $true
            $cachedButton.Current.IsOffscreen = $true
        }
        7 {
            Check-Display 'offscreen button' $false
            $cachedButton.Current.IsOffscreen = $false
            $script:fixtureForeground = $fixtureHandle
            $checks.Interval = [TimeSpan]::FromSeconds(6)
        }
        8 {
            Check-Display 'button available again' $true
            $checks.Interval = [TimeSpan]::FromMilliseconds(1400)
            $fixture.Close()
        }
        9 {
            Check-Display 'closed owner with process still alive' $false
            $window.Close()
            $checks.Stop()
        }
    }
    $testState.Step++
})
$source = $source.Replace('$tick.Start()', '$tick.Start(); $checks.Start()')
try {
    . ([scriptblock]::Create($source))
    if ($testState.Step -eq 9) {
        Check-Display 'closed owner with process still alive' $false
    }
} finally {
    $checks.Stop()
    $fixture.Close()
}
$results | ConvertTo-Json
if ($results.Count -ne 9 -or @($results | Where-Object { -not $_.passed }).Count) {
    throw 'Window lifecycle regression failed'
}
