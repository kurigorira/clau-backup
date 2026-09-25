# =====================================================================
#  タスクスケジューラへの登録（管理者の PowerShell で1回だけ実行）
#    - 毎日 2:00 に backup.ps1 を実行する
#    - サーバーが 2:00 に止まっていた場合は、起動後にすぐ実行する
#    - NAS に書き込めるバックアップ専用アカウントで実行する
#
#  例: .\register-task.ps1 -RunAsUser 'SERVER01\svc_backup'
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunAsUser,
    [string]$At = '02:00',
    [string]$TaskName = 'WebServer Daily Backup',
    [string]$EventSource = 'WebServerBackup'
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'backup.ps1'

# イベントログのソース登録（失敗・警告をイベントビューアーでも見られるように）
if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    New-EventLog -LogName Application -Source $EventSource
    Write-Host "イベントソースを登録しました: $EventSource"
}

$cred = Get-Credential -UserName $RunAsUser -Message 'バックアップを実行するアカウントのパスワード'

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" -WorkingDirectory $PSScriptRoot
$trigger  = New-ScheduledTaskTrigger -Daily -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
            -MultipleInstances IgnoreNew -RestartCount 1 -RestartInterval (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null

Write-Host "登録しました: $TaskName（毎日 $At、実行ユーザー $RunAsUser）"
Write-Host "すぐに試すには: Start-ScheduledTask -TaskName '$TaskName'"
