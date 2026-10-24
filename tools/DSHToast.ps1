<#
    DSHToast.ps1 - show a high-priority Windows toast for the attention monitor.

    The toast carries the DeepSeek Harness AppUserModelID (com.deepseek.dsh,
    taken from the app's Start Menu shortcut), so Windows shows the app's own
    name and icon instead of a generic script identity.

    Priority is set to High so the toast can break through Do Not Disturb while
    the user's "priority notifications" setting allows the app to.

    Clicking the toast launches the dsh-attention: protocol, which the monitor
    script registers for tools\DSHActivate.ahk.

    Written in plain ASCII on purpose: Windows PowerShell 5.1 reads a BOM-less
    script as ANSI, so non-ASCII text belongs in the parameters, not in here.
#>
param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Text,
    [string]$Launch = 'dsh-attention:activate',
    [string]$Aumid = 'com.deepseek.dsh'
)

$ErrorActionPreference = 'Stop'

[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

$xmlText = @"
<toast launch="$Launch" activationType="protocol">
  <visual>
    <binding template="ToastGeneric">
      <text>$([System.Security.SecurityElement]::Escape($Title))</text>
      <text>$([System.Security.SecurityElement]::Escape($Text))</text>
    </binding>
  </visual>
</toast>
"@

$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml($xmlText)

$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
$toast.Priority = [Windows.UI.Notifications.ToastNotificationPriority]::High

try {
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid).Show($toast)
}
catch {
    # Fall back to the Windows PowerShell identity when the app's AUMID is not
    # registered here (the app was not installed with a Start Menu shortcut).
    $fallback = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($fallback).Show($toast)
}
