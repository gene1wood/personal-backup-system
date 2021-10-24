#Requires -Version 6

# First install Powershell 7 outside of this script as Powershell 5 is the deafult in Windows 10
# https://github.com/PowerShell/PowerShell/releases/latest
# https://github.com/PowerShell/PowerShell/releases/download/v7.1.4/PowerShell-7.1.4-win-x64.msi

####

# Manual Steps
# Create C:\duplicacy\keys\id_*_$CLIENT
# Download C:\duplicacy\setup-client.ps1
# Download or create C:\duplicacy\config.ps1
# Run Powershell as administrator
# Enable running scripts by typing "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser"
# Type "y"
# Type in the full path to setup-client.ps1 to launch it

Set-PSDebug -Trace 2

# Abort if any error
$ErrorActionPreference="Stop"

$DUPLICACY_URL = 'https://github.com/gilbertchen/duplicacy/releases/download/v2.7.2/duplicacy_win_x64_2.7.2.exe'
$SCHEDULED_TASK_URL = 'https://raw.githubusercontent.com/gene1wood/personal-backup-system/master/windows-client/run-scheduled-duplicacy-backup.ps1'
$FILTER_URL = 'https://raw.githubusercontent.com/gene1wood/personal-backup-system/master/windows-client/duplicacy-filters-windows.txt'

$DUPLICACY_BASEDIR = 'C:\duplicacy'
New-Item -Path "$DUPLICACY_BASEDIR" -ItemType 'directory' -Force
New-Item -Path "$DUPLICACY_BASEDIR" -Name 'backup\.duplicacy' -ItemType 'directory' -Force
New-Item -Path "$DUPLICACY_BASEDIR" -Name 'keys' -ItemType 'directory' -Force
New-Item -Path "$DUPLICACY_BASEDIR" -Name 'logs' -ItemType 'directory' -Force
New-Item -Path "$DUPLICACY_BASEDIR" -Name 'bin' -ItemType 'directory' -Force

. ("C:\duplicacy\config.ps1")
if ($null -eq $SERVER -Or $null -eq $SERVER_PORT -Or $null -eq $KNOWN_HOSTS_STRING) {
    throw "C:\duplicacy\config.ps1 is missing variables. SERVER SERVER_PORT and KNOWN_HOSTS_STRING are needed"
}

$CLIENT = "$env:computername".ToLower()

$SFTP_URI = "sftp://{0}@{1}:{2}/backup" -f $CLIENT, $SERVER, $SERVER_PORT
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Set-Item -Path Env:DUPLICACY_SSH_KEY_FILE -Value "$KEY_FILE_NAME"

$STORAGE_PASSWORD = Read-Host "Please enter the Duplicacy storage encryption password"
Set-Item -Path Env:DUPLICACY_PASSWORD -Value $STORAGE_PASSWORD


while ($true) {
    if (( Get-ChildItem $DUPLICACY_BASEDIR\backup | Measure-Object ).Count -le 1 ) {
        Write-Host -NoNewLine "Setup links now.
    Example, run in cmd as administrator
    cmd /c mklink /D $DUPLICACY_BASEDIR\backup\C-Users-IEUser-AppData-Roaming C:\Users\IEUser\AppData\Roaming"
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
    }
    else {
        break
    }

}

while ($true) {
    $KEY_FILE = Get-Item "$DUPLICACY_BASEDIR\keys\id_*_$CLIENT"
    if (!$KEY_FILE) {
        Write-Host -NoNewLine "Create OpenSSH private key $DUPLICACY_BASEDIR\keys\id_*_$CLIENT and press a key";
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
    }
    else {
        break
    }

}
$KEY_FILE_NAME = $KEY_FILE.FullName

# Temporarily secure the private key with our current user to use it to sftp provision the server
# later we'll secure it so it can be used in the scheduled task
# https://superuser.com/a/1329702
# /C indicates that this operation will continue on all file errors. Error messages will still be displayed.
# /T indicates that this operation is performed on all matching files/directories below the directories specified in the name.
# Remove Inheritance
icacls $KEY_FILE_NAME /c /t /inheritance:d
# Set owner to current user
$CURRENT_USER = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls $KEY_FILE_NAME /c /t /grant ${CURRENT_USER}:F
# Remove All Users, except for Owner
icacls $KEY_FILE_NAME /c /t /remove Administrator "Authenticated Users" Everyone Users Administrators
# Verify
icacls $KEY_FILE_NAME

Write-Output $KNOWN_HOSTS_STRING | Out-File -FilePath "$DUPLICACY_BASEDIR\keys\known_hosts"
$KNOWN_HOSTS_FILE = Get-Item "$DUPLICACY_BASEDIR\keys\known_hosts"
$KNOWN_HOSTS_FILE_NAME = $KNOWN_HOSTS_FILE.FullName

$sftp_arguments = @('-o', 'BatchMode=yes', '-o', "Port=$SERVER_PORT", '-o', "IdentityFile=$KEY_FILE_NAME", '-o', "UserKnownHostsFile=$KNOWN_HOSTS_FILE_NAME", "$CLIENT@$SERVER")
while ($true) {
    Write-Output "pwd" | & "C:\Windows\System32\OpenSSH\sftp.exe" @sftp_arguments | findstr "Remote working directory: /"
    if ($LASTEXITCODE -ne 0) {
        Write-Host -NoNewLine "Fix sftp and press a key";
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
    }
    else {
        break
    }
}

(Test-Path "$DUPLICACY_BASEDIR\backup\.duplicacy\filters") -or (Invoke-WebRequest "$FILTER_URL" -OutFile "$DUPLICACY_BASEDIR\backup\.duplicacy\filters")

(Test-Path "$DUPLICACY_BASEDIR\bin\duplicacy.exe") -or (Invoke-WebRequest "$DUPLICACY_URL" -OutFile "$DUPLICACY_BASEDIR\bin\duplicacy.exe")

Set-Location -Path "$DUPLICACY_BASEDIR\backup"

$arguments = @('init', '-encrypt', '-repository', "$DUPLICACY_BASEDIR\backup", $CLIENT, $SFTP_URI)
& "$DUPLICACY_BASEDIR\bin\duplicacy.exe" @arguments

if (!(Test-Path -Path "$DUPLICACY_BASEDIR\backup\.duplicacy\preferences" -PathType Leaf)) {
    throw "$DUPLICACY_BASEDIR\backup\.duplicacy\preferences wasn't created on duplicacy init. aborting"
}

Write-Output 'mkdir backup/logs' | & sftp @sftp_arguments

$arguments = @('set', '-key', 'ssh_key_file', '-value', "$KEY_FILE_NAME")
& "$DUPLICACY_BASEDIR\bin\duplicacy.exe" @arguments

while ($true) {
    $prefs = Get-Content "$DUPLICACY_BASEDIR\backup\.duplicacy\preferences" | ConvertFrom-Json
    if (!(Get-Member -inputobject $prefs.keys -name 'password' -Membertype Properties)) {
        Write-Host -NoNewLine "You'll need to manually add the encryption password to $DUPLICACY_BASEDIR/backup/.duplicacy/preferences under keys... password"
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
    }
    else {
        break
    }
}

$LOG_BASEDIR = "$DUPLICACY_BASEDIR\logs"
Write-Output """$((Get-Command pwsh.exe).Definition)"" ""$DUPLICACY_BASEDIR\bin\run-scheduled-duplicacy-backup.ps1"" > ""$LOG_BASEDIR\last-run.txt"" 2>&1" | Out-File "$DUPLICACY_BASEDIR\bin\scheduled-task.cmd"
# https://superuser.com/a/1289863

(Test-Path "$DUPLICACY_BASEDIR\bin\run-scheduled-duplicacy-backup.ps1") -or (Invoke-WebRequest "$SCHEDULED_TASK_URL" -OutFile "$DUPLICACY_BASEDIR\bin\run-scheduled-duplicacy-backup.ps1")

# Secure the SSH private key so it's usable by the scheduled task
# https://superuser.com/a/1329702
# /C indicates that this operation will continue on all file errors. Error messages will still be displayed.
# /T indicates that this operation is performed on all matching files/directories below the directories specified in the name.
# Remove Inheritance
icacls $KEY_FILE_NAME /c /t /inheritance:d
# Set Ownership to Owner
# Note on the `"NT AUTHORITY\System`" trick : https://serverfault.com/a/516327
icacls $KEY_FILE_NAME /c /t /grant `"NT AUTHORITY\System`":F
# Remove All Users, except for Owner
icacls $KEY_FILE_NAME /c /t /remove Administrator "Authenticated Users" Everyone Users Administrators $CURRENT_USER
# Verify
icacls $KEY_FILE_NAME

$ACL = Get-ACL $KEY_FILE_NAME
$System_User = New-Object System.Security.Principal.NTAccount("NT AUTHORITY", "SYSTEM")
$ACL.SetOwner($System_User)
Set-Acl -Path $KEY_FILE_NAME -AclObject $ACL

$Action = New-ScheduledTaskAction -Id 'RunScheduledDuplicacyBackup' -Execute "$DUPLICACY_BASEDIR\bin\scheduled-task.cmd" -WorkingDirectory $DUPLICACY_BASEDIR
$Trigger = New-ScheduledTaskTrigger -At 1:00am -Daily -RandomDelay (New-TimeSpan -Hours 3)
$SettingSet = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RunOnlyIfNetworkAvailable -StartWhenAvailable
Register-ScheduledTask -TaskName 'RunScheduledDuplicacyBackup' -Trigger $Trigger -User 'NT AUTHORITY\SYSTEM' -Action $Action -Settings $SettingSet -Description 'Incremental backup with duplicacy followed by pruning' -Force

# Enable Task Scheduler History
# https://stackoverflow.com/a/40577338/168874
wevtutil set-log Microsoft-Windows-TaskScheduler/Operational /enabled:true

# Note
# To temporarily give yourself access to the private key
# $CLIENT = "$env:computername".ToLower()
# $KEY_FILE = Get-Item "C:\duplicacy\keys\id_*_$CLIENT"
# $KEY_FILE_NAME = $KEY_FILE.FullName
# $CURRENT_USER = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
# takeown /F $KEY_FILE_NAME
# icacls $KEY_FILE_NAME /c /t /grant ${CURRENT_USER}:F
# 
# Then when you're done
# 
# icacls $KEY_FILE_NAME /setowner `"NT AUTHORITY\System`"
# icacls $KEY_FILE_NAME /c /t /grant `"NT AUTHORITY\System`":F
# icacls $KEY_FILE_NAME /c /t /remove Administrator "Authenticated Users" Everyone Users Administrators $CURRENT_USER

Write-Output "Duplicacy setup complete"
