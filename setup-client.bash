#!/bin/bash -e

DUPLICACY_URL="https://github.com/gilbertchen/duplicacy/releases/download/v3.1.0/duplicacy_linux_x64_3.1.0"
DUPLICACY_BASEDIR=/opt/duplicacy

message () {
  GREEN='\033[1;32m'
  NOCOLOR='\033[0m' # No Color
  echo -e "${GREEN}$1${NOCOLOR}"
}

if [ ! -e config.bash ]; then
  message "Unable to find config.bash"
  exit 1
fi

source config.bash
if [ -z "${SERVER}" -o -z "${SERVER_PORT}" -o -z "${KNOWN_HOSTS_STRING}" ]; then
    message "Config variables are missing. export SERVER SERVER_PORT and KNOWN_HOSTS_STRING and run this setup again."
    exit 1
fi

while ! (which sftp && which wget && which openssl) >/dev/null; do
    message "Unable to find some executable (sftp, wget, openss), they need to be installed"
    read -s -n 1 -p "Go do this, then press any key to continue . . ."
done

mkdir --parents --verbose ${DUPLICACY_BASEDIR}/bin ${DUPLICACY_BASEDIR}/keys ${DUPLICACY_BASEDIR}/backup ${DUPLICACY_BASEDIR}/logs
chmod --verbose 700 ${DUPLICACY_BASEDIR}/keys
if [[ ! -e "${DUPLICACY_BASEDIR}/bin/duplicacy" ]]; then
    wget "$DUPLICACY_URL" -O "$DUPLICACY_BASEDIR/bin/duplicacy"
    chmod --verbose 755 ${DUPLICACY_BASEDIR}/bin/duplicacy
fi

while [ $(ls -1 ${DUPLICACY_BASEDIR}/backup | wc -l) -le 1 ]; do
    message "You'll need to setup all you symbolic links in ${DUPLICACY_BASEDIR}/backup/"
    message "Example : ln --verbose --symbolic /boot ${DUPLICACY_BASEDIR}/backup/boot"
    read -s -n 1 -p "Go do this, then press any key to continue . . ."
done

CLIENT=$(hostname --short)

KEY_FILE="`readlink -f ${DUPLICACY_BASEDIR}/keys/id_*_${CLIENT}`"

while [[ ! -e "${KEY_FILE}" ]]; do
    message "Copy the private key over from the server into ${KEY_FILE}"
    read -s -n 1 -p "Go do this, then press any key to continue . . ."
    KEY_FILE="`readlink -f ${DUPLICACY_BASEDIR}/keys/id_*_${CLIENT}`"
done
chmod --verbose 600 ${KEY_FILE}

KNOWN_HOSTS=${DUPLICACY_BASEDIR}/keys/known_hosts
echo -e "${KNOWN_HOSTS_STRING}" > ${KNOWN_HOSTS}

cd ${DUPLICACY_BASEDIR}/backup

while [ -z "$ENCRYPTION_ARGUMENT" ]; do
    read -p "Would you like synchronous encryption or RSA asynchronous encryption? (sync / async) : "
    if [ "$REPLY" = "sync" ]; then
      ENCRYPTION_ARGUMENT="-encrypt"
    elif [ "$REPLY" = "async" ]; then
      if ! [ -e "${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_private.pem" ]; then
        openssl genrsa -aes256 -out "${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_private.pem" 2048
        openssl rsa -in  "${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_private.pem" -pubout -out "${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_public.pem"
      fi
      ENCRYPTION_ARGUMENT="-encrypt -key ${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_public.pem"
    else
      message "Please type sync or async"
    fi
done

message "About to initialize the backup. Enter the encryption password you'd like to use with this backup when prompted for the \"storage password\""
DUPLICACY_SSH_KEY_FILE="${KEY_FILE}" "${DUPLICACY_BASEDIR}/bin/duplicacy" init ${ENCRYPTION_ARGUMENT} -repository ${DUPLICACY_BASEDIR}/backup ${CLIENT} sftp://${CLIENT}@${SERVER}:${SERVER_PORT}/backup
# This is where you interactively enter the password
echo "mkdir backup/logs" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER}

FILTER_FILE="${DUPLICACY_BASEDIR}/backup/.duplicacy/filters"
if [[ ! -e "${FILTER_FILE}" ]]; then
    message "Fetching /opt/duplicacy/backup/.duplicacy/filters"
    wget -O "${FILTER_FILE}" https://raw.githubusercontent.com/gene1wood/personal-backup-system/master/duplicacy-filters-linux.txt
fi

"${DUPLICACY_BASEDIR}/bin/duplicacy" set -key ssh_key_file -value "${KEY_FILE}"

while ! grep '"password"' ${DUPLICACY_BASEDIR}/backup/.duplicacy/preferences >/dev/null; do
    message "You'll need to manually add the encryption password to /opt/duplicacy/backup/.duplicacy/preferences under keys... password"
    # Probably want to avoid using set until this bug is fixed https://github.com/gilbertchen/duplicacy/issues/526
    # Or maybe not? Maybe the issue was the double quotes around the password? Though "&<>" are all escaped by the go json library
    # it doesn't seem to be a problem.
        #set +o history
        #${DUPLICACY_BASEDIR}/bin/duplicacy set -key password -value 'the-password-goes-here'
        #set -o history
    read -s -n 1 -p "Go do this, then press any key to continue . . ."
done

if [[ ! -e "${DUPLICACY_BASEDIR}/bin/config.bash" ]]; then
    echo "SERVER_PORT=${SERVER_PORT}" > "${DUPLICACY_BASEDIR}/bin/config.bash"
    echo "SERVER=${SERVER}" >> "${DUPLICACY_BASEDIR}/bin/config.bash"
fi

if [[ ! -e "${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash" ]]; then
    wget -O "${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash" https://raw.githubusercontent.com/gene1wood/personal-backup-system/master/run-scheduled-duplicacy-backup.bash
    chmod --verbose 755 "${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash"
fi


init_system=$(ps --no-headers -o comm 1)
if [ "${init_system}" = "systemd" ]; then
    cat << END-OF-FILE > /etc/systemd/system/scheduled-duplicacy-backup.service
[Unit]
Description=Incremental backup with Duplicacy followed by pruning

[Service]
Type=oneshot
ExecStart=${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash
END-OF-FILE
    cat << END-OF-FILE > /etc/systemd/system/scheduled-duplicacy-backup.timer
[Unit]
Description=Run scheduled-duplicacy-backup.service every night between 1AM and 4AM

[Timer]
OnCalendar=*-*-* 01:00:00
# triggers the service immediately if it missed the last start time
Persistent=true
# Delay between 0 and 3 hours in seconds (3 * 60 * 60 = 10800)
RandomizedDelaySec=10800

[Install]
WantedBy=timers.target
END-OF-FILE
    systemctl enable scheduled-duplicacy-backup.timer --now
    message "# To do a real first backup"
    message "# For systemd run (yes, you actually need screen because this will run for a long time)"
    message "screen"
    message "systemctl start scheduled-duplicacy-backup.service"
else
    # Note : the \$ is to escape the HEREDOC. The \% is to escape the crontab
    cat << END-OF-FILE > /etc/cron.d/scheduled-duplicacy-backup.cron
SHELL=/bin/bash
# Run scheduled-duplicacy-backup.service every night between 1AM and 4AM
# Delay between 0 and 3 hours in seconds (3 * 60 * 60 = 10800)
0 1 * * * root sleep \$[RANDOM \% 10800]; ${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash
END-OF-FILE
  message "# To do a real first backup"
  message "# For cron run"
  message "screen"
  message "/opt/duplicacy/bin/run-scheduled-duplicacy-backup.bash"
fi

message "To do a dry run to see what would be backed up run"
message "cd ${DUPLICACY_BASEDIR}/backup"
message "${DUPLICACY_BASEDIR}/bin/duplicacy backup -stats -dry-run | tee -a ${DUPLICACY_BASEDIR}/logs/duplicacy.dry-run.${CLIENT}.\`date +%Y%m%d%H%M%S\`.txt"
message "And if you used RSA encryption, remove the private key from the client and store it somewhere safe"
