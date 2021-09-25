# This requires Powershell 6
# For example to get MaximumRetryCount on Invoke-WebRequest

Set-PSDebug -Trace 2

Write-Output "$(Get-Date -UFormat "%Y-%m-%d %H:%M:%S") Starting"
$USERNAME = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Output "Running as $USERNAME"
. ("C:\duplicacy\config.ps1")
if ($null -eq $SERVER -Or $null -eq $SERVER_PORT) {
    Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") ERROR PARENT_UPDATE SERVER or SERVER_PORT not configured" >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"
    exit 1
}

$CLIENT = "$env:computername".ToLower()
$DUPLICACY_BASEDIR = "C:\duplicacy"
$LOG_BASEDIR = "$DUPLICACY_BASEDIR\logs"
$log_file_name = "duplicacy.$CLIENT.$(Get-Date -UFormat "%Y%m%d%H%M%S").txt"
$log_file = "$LOG_BASEDIR\$log_file_name"

$KEY_FILE = Get-Item "$DUPLICACY_BASEDIR\keys\id_*_$CLIENT"
$KEY_FILE_NAME = $KEY_FILE.FullName
$KNOWN_HOSTS_FILE = Get-Item "$DUPLICACY_BASEDIR\keys\known_hosts"
$KNOWN_HOSTS_FILE_NAME = $KNOWN_HOSTS_FILE.FullName

$i = 0
$network_active = 0
while ($i -lt 5) {
    Invoke-WebRequest "http://www.google.com/"
    if ($?) {
        $network_active = 1
        break
    }
    Start-Sleep -Seconds 5
}

if (-not $network_active) {
    Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") ERROR PARENT_UPDATE No network connectivity" >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"
    exit 1
}

if (!(Test-Path "$DUPLICACY_BASEDIR\hc_uuid")) {

    $arguments = @("-o", "Port=$SERVER_PORT", "-o", "IdentityFile=$KEY_FILE_NAME", "-o", "UserKnownHostsFile=$KNOWN_HOSTS_FILE_NAME", "-o", "BatchMode=yes", "$CLIENT@$SERVER")
    Write-Output "get hc_uuid $DUPLICACY_BASEDIR\" | & "C:\Windows\System32\OpenSSH\sftp.exe" @arguments
}

$hc_uuid = Get-Content "$DUPLICACY_BASEDIR\hc_uuid" -First 1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest "https://hc-ping.com/$hc_uuid/start" -MaximumRetryCount 3 -RetryIntervalSec 1

Set-Location -Path "$DUPLICACY_BASEDIR\backup"

Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") INFO PARENT_UPDATE Beginning backup : duplicacy -log backup -stats" | Tee-Object -Append $log_file >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"

$arguments = @("-log", "backup", "-stats")
& "$DUPLICACY_BASEDIR\bin\duplicacy.exe" @arguments | Out-File $log_file -Append
if ($LASTEXITCODE -ne 0) {
    Invoke-WebRequest "https://hc-ping.com/$hc_uuid/fail" -MaximumRetryCount 3 -RetryIntervalSec 1
    Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") ERROR PARENT_UPDATE Backup failed" | Tee-Object -Append $log_file >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"
}
else {
    Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") INFO PARENT_UPDATE Backup succeeded" | Tee-Object -Append $log_file >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"
    Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") INFO PARENT_UPDATE Beginning prune : duplicacy -log prune -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7" | Tee-Object -Append $log_file >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"

    $arguments = @("-log", "prune", "-keep", "0:360", "-keep", "30:180", "-keep", "7:30", "-keep", "1:7")
    # TODO : Decide if we should put a -threads argument in the prune
    & "$DUPLICACY_BASEDIR\bin\duplicacy.exe" @arguments | Out-File $log_file -Append
    if ($LASTEXITCODE -ne 0) {
        Invoke-WebRequest "https://hc-ping.com/$hc_uuid/fail" -MaximumRetryCount 3 -RetryIntervalSec 1
        Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") ERROR PARENT_UPDATE Prune failed" | Tee-Object -Append $log_file >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"
    }
    else {
        Invoke-WebRequest "https://hc-ping.com/$hc_uuid" -MaximumRetryCount 3 -RetryIntervalSec 1
        Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") INFO PARENT_UPDATE Prune succeeded" | Tee-Object -Append $log_file >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"
    }
}

$arguments = @("-o", "Port=$SERVER_PORT", "-o", "IdentityFile=$KEY_FILE_NAME", "-o", "UserKnownHostsFile=$KNOWN_HOSTS_FILE_NAME", "-o", "BatchMode=yes", "$CLIENT@$SERVER")
Write-Output "put ""$log_file"" backup/logs/`nrm ""backup/logs/duplicacy.$CLIENT.latest.txt""`nsymlink ""$log_file_name"" ""backup/logs/duplicacy.$CLIENT.latest.txt""" | & "C:\Windows\System32\OpenSSH\sftp.exe" @arguments

if ($LASTEXITCODE -eq 0) {
    Remove-Item "$log_file"
    Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") INFO PARENT_UPDATE Log push succeeded" >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"
}
else {
    Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") INFO PARENT_UPDATE Log push failed" >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"
}
Write-Output "$(Get-Date -UFormat "%Y%m%d%H%M%S") INFO PARENT_UPDATE Backup job complete" >> "$LOG_BASEDIR/duplicacy.$CLIENT.txt"