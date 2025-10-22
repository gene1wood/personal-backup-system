#!/bin/bash -e

VERSION=2.0.0

DUPLICACY_URL="https://github.com/gilbertchen/duplicacy/releases/download/v3.2.4/duplicacy_linux_x64_3.2.4"
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
if [ -z "${KNOWN_HOSTS_STRING}" -o -z "${BACKUP_DIRECTORY}" ]; then
    message "Config variables are missing. export SERVER SERVER_PORT BACKUP_DIRECTORY and KNOWN_HOSTS_STRING and run this setup again."
    exit 1
fi
if [ -z "${SERVER}" -a -z "${SERVER_PORT}" -a -z "${LOCAL_DESTINATION_DIRECTORY}" ]; then
    message "Config variables are missing. Either set SERVER and SERVER_PORT or set LOCAL_DESTINATION_DIRECTORY."
    exit 1
fi

if [ "${LOCAL_DESTINATION_DIRECTORY}" ] && [ ! -d "${LOCAL_DESTINATION_DIRECTORY}" ]; then
    echo "${LOCAL_DESTINATION_DIRECTORY} directory doesn't exist"
    exit 1
fi

while ! (which sftp && which wget && which openssl && which python3) >/dev/null; do
    message "Unable to find some executable (sftp, wget, openssl, python3), they need to be installed"
    read -s -n 1 -p "Go do this, then press any key to continue . . ."
done

mkdir --parents --verbose ${DUPLICACY_BASEDIR}/bin ${DUPLICACY_BASEDIR}/keys ${BACKUP_DIRECTORY} ${DUPLICACY_BASEDIR}/logs
chmod --verbose 700 ${DUPLICACY_BASEDIR}/keys
if [[ ! -e "${DUPLICACY_BASEDIR}/bin/duplicacy" ]]; then
    wget "$DUPLICACY_URL" -O "$DUPLICACY_BASEDIR/bin/duplicacy"
    chmod --verbose 755 ${DUPLICACY_BASEDIR}/bin/duplicacy
fi

while [ $(ls -1 ${BACKUP_DIRECTORY} | wc -l) -lt 1 ]; do
    message "You'll need to setup all you symbolic links in ${BACKUP_DIRECTORY}"
    message "Example : ln --verbose --symbolic /boot ${BACKUP_DIRECTORY}/boot"
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

# If the known_hosts file doesn't exist or the contents differ from the KNOWN_HOSTS_STRING, update the file
KNOWN_HOSTS=${DUPLICACY_BASEDIR}/keys/known_hosts
if [ ! -e "${KNOWN_HOSTS}" ] || [[ "$(< ${KNOWN_HOSTS})" != "${KNOWN_HOSTS_STRING}" ]]; then
    echo -e "${KNOWN_HOSTS_STRING}" > ${KNOWN_HOSTS}
fi
cd ${BACKUP_DIRECTORY}

while [ -z "$ENCRYPTION_ARGUMENT" ]; do
    read -p "Would you like synchronous encryption or RSA asynchronous encryption? (sync / async) : "
    if [ "$REPLY" = "sync" ]; then
      ENCRYPTION_ARGUMENT="-encrypt"
    elif [ "$REPLY" = "async" ]; then
      if ! [ -e "${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_private.pem" ]; then
        # The need for the -traditional is due to https://forum.duplicacy.com/t/duplicacy-restore-of-encrypted-backup-fails-with-error/3862/14
        if openssl version | grep "OpenSSL 3" >/dev/null; then
          TRADITIONAL_ARG="-traditional"
        else
          TRADITIONAL_ARG=""
        fi
        openssl genrsa -aes256 ${TRADITIONAL_ARG} -out "${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_private.pem" 2048
        openssl rsa -in  "${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_private.pem" -pubout -out "${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_public.pem"
      fi
      ENCRYPTION_ARGUMENT="-encrypt -key ${DUPLICACY_BASEDIR}/keys/${CLIENT}_duplicacy_encryption_key_public.pem"
    else
      message "Please type sync or async"
    fi
done

if [ "${SERVER}" -a "${SERVER_PORT}" ]; then
    DESTINATION_URI="sftp://${CLIENT}@${SERVER}:${SERVER_PORT}/backup"
elif [ "${LOCAL_DESTINATION_DIRECTORY}" ]; then
    DESTINATION_URI="${LOCAL_DESTINATION_DIRECTORY}"
else
    echo "Missing either SERVER and SERVER_PORT or LOCAL_DESTINATION_DIRECTORY"
    exit 1
fi

message "About to initialize the backup. Enter the encryption password you'd like to use with this backup when prompted for the \"storage password\""
DUPLICACY_SSH_KEY_FILE="${KEY_FILE}" "${DUPLICACY_BASEDIR}/bin/duplicacy" init ${ENCRYPTION_ARGUMENT} -repository ${BACKUP_DIRECTORY} ${CLIENT} ${DESTINATION_URI}
# This is where you interactively enter the password
if [ "${LOCAL_DESTINATION_DIRECTORY}" ]; then
    mkdir --verbose "${LOCAL_DESTINATION_DIRECTORY}/logs"
else
    echo "mkdir backup/logs" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER}
fi

FILTER_FILE="${BACKUP_DIRECTORY}/.duplicacy/filters"
if [[ ! -e "${FILTER_FILE}" ]]; then
    message "Fetching ${BACKUP_DIRECTORY}/.duplicacy/filters"
    wget -O "${FILTER_FILE}" https://raw.githubusercontent.com/gene1wood/personal-backup-system/master/duplicacy-filters-linux.txt
fi

"${DUPLICACY_BASEDIR}/bin/duplicacy" set -key ssh_key_file -value "${KEY_FILE}"

while ! grep '"password"' ${BACKUP_DIRECTORY}/.duplicacy/preferences >/dev/null; do
    message "You'll need to manually add the encryption password to ${BACKUP_DIRECTORY}/.duplicacy/preferences under keys... password"
    # Probably want to avoid using set until this bug is fixed https://github.com/gilbertchen/duplicacy/issues/526
    # Or maybe not? Maybe the issue was the double quotes around the password? Though "&<>" are all escaped by the go json library
    # it doesn't seem to be a problem.
        #set +o history
        #${DUPLICACY_BASEDIR}/bin/duplicacy set -key password -value 'the-password-goes-here'
        #set -o history
    read -s -n 1 -p "Go do this, then press any key to continue . . ."
done

if [[ ! -e "${DUPLICACY_BASEDIR}/bin/config.bash" ]]; then
    while [ -z "$hc_uuid" ]; do
        read -p "What is this clients healthchecks.io UUID : "
        if [[ $REPLY =~ ^\{?[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}\}?$ ]]; then
            hc_uuid=$REPLY
        fi
    done
    echo "HC_UUID=${hc_uuid}" >> "${DUPLICACY_BASEDIR}/bin/config.bash"
    echo "BACKUP_DIRECTORIES=(\"${BACKUP_DIRECTORY}\")" >> "${DUPLICACY_BASEDIR}/bin/config.bash"
else
    # Because programatically modifying the /opt/duplicacy/bin/config.bash file is super complex, just tell the user to do it
    # This assumed that BACKUP_DIRECTORIES is set in ${DUPLICACY_BASEDIR}/bin/config.bash (which it might not be)

    # TODO : Make this echo the green message color
    bash -c "source \"${DUPLICACY_BASEDIR}/bin/config.bash\"; if ! printf '%s\0' \"\${BACKUP_DIRECTORIES[@]}\" | grep -Fxqz -- \"\$0\"; then echo -e \"Modify /opt/duplicacy/bin/config.bash and add \$0 to BACKUP_DIRECTORIES_ARRAY\"; fi" "${BACKUP_DIRECTORY}"
fi

if [[ ! -e "${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash" ]]; then
    wget -O "${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash" https://raw.githubusercontent.com/gene1wood/personal-backup-system/master/run-scheduled-duplicacy-backup.bash
    chmod --verbose 755 "${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash"
fi

init_system=$(ps --no-headers -o comm 1)
if [ "${init_system}" = "systemd" ]; then
    if [ ! -e /etc/systemd/system/scheduled-duplicacy-backup.service ]; then
        cat << END-OF-FILE > /etc/systemd/system/scheduled-duplicacy-backup.service
[Unit]
Description=Incremental backup with Duplicacy followed by pruning

[Service]
Type=oneshot
ExecStart=${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash
END-OF-FILE
    fi
    if [ ! -e /etc/systemd/system/scheduled-duplicacy-backup.timer ]; then
        cat << END-OF-FILE > /etc/systemd/system/scheduled-duplicacy-backup.timer
[Unit]
Description=Run scheduled-duplicacy-backup.service every night between 1AM and 4AM PST

[Timer]
OnCalendar=*-*-* 09:00:00 UTC
# triggers the service immediately if it missed the last start time
Persistent=true
# Delay between 0 and 3 hours in seconds (3 * 60 * 60 = 10800)
RandomizedDelaySec=10800

[Install]
WantedBy=timers.target
END-OF-FILE
        systemctl enable scheduled-duplicacy-backup.timer --now
    fi
    message "# To do a real first backup"
    message "# For systemd run (yes, you actually need screen because this will run for a long time)"
    message "screen"
    message "systemctl start scheduled-duplicacy-backup.service"
else
    # Note : the \$ is to escape the HEREDOC. The \% is to escape the crontab
    if [ ! -e /etc/cron.d/scheduled-duplicacy-backup.cron ]; then
        cat << END-OF-FILE > /etc/cron.d/scheduled-duplicacy-backup.cron
SHELL=/bin/bash
# Run scheduled-duplicacy-backup.service every night between 1AM and 4AM
# Delay between 0 and 3 hours in seconds (3 * 60 * 60 = 10800)
0 1 * * * root sleep \$[RANDOM \% 10800]; ${DUPLICACY_BASEDIR}/bin/run-scheduled-duplicacy-backup.bash
END-OF-FILE
    fi
    message "# To do a real first backup"
    message "# For cron run"
    message "screen"
    message "/opt/duplicacy/bin/run-scheduled-duplicacy-backup.bash"
fi

message "To do a dry run to see what would be backed up run"
message "cd ${BACKUP_DIRECTORY}"
message "${DUPLICACY_BASEDIR}/bin/duplicacy backup -stats -dry-run | tee -a ${DUPLICACY_BASEDIR}/logs/duplicacy.dry-run.${CLIENT}.\`date +%Y%m%d%H%M%S\`.txt"
case $ENCRYPTION_ARGUMENT in
    *-key* )
         message "Make sure to remove the RSA private key from the client and store it somewhere safe"
         ;;
esac