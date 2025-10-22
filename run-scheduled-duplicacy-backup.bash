#!/bin/bash -e

# Install this file in /opt/duplicacy/bin/run-scheduled-duplicacy-backup.bash

VERSION=2.0.0
. /opt/duplicacy/bin/config.bash
if [ -z "${HC_UUID}" ]; then
    echo "Config isn't set. Aborting"
    exit 1
fi
which python3 >/dev/null || { echo "Unable to find python3" && exit 1; }
if [ -z "${BACKUP_DIRECTORIES}" ]; then
  # config.bash doesn't have BACKUP_DIRECTORIES set
  BACKUP_DIRECTORIES=("/opt/duplicacy/backup")
fi
DUPLICACY_BASEDIR=/opt/duplicacy
LOG_BASEDIR="${DUPLICACY_BASEDIR}/logs"
# CLIENT is now derived from the duplicacy preferences file
CLIENT_INDIVIDUAL_ID="${CLIENT_INDIVIDUAL_ID:-$(hostname --short)}"

duplicacy_prune () {
    echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Beginning prune : duplicacy -log prune -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
    ${DUPLICACY_BASEDIR}/bin/duplicacy -log prune -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7 | tee -a ${log_file}
    if [ "${PIPESTATUS[0]}" != 0 ]; then
        # TODO : Decide if we should put a -threads argument in the prune
        curl --fail --silent --show-error --retry 3 --data-raw "Duplicacy prune returned a non-zero exit code" https://hc-ping.com/${HC_UUID}/fail
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Prune failed" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
    else
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Prune succeeded" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
    fi
}

(
    flock --nonblock 200 || exit 1

    # Setup logging
    true >${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.lastrun.txt
    chmod 640 "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.lastrun.txt"

    log_file_name="duplicacy.$(hostname --short).`date +%Y%m%d%H%M%S`.txt"
    log_file="${LOG_BASEDIR}/${log_file_name}"
    touch "${log_file}"
    chmod 640 "${log_file}"
    touch "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
    chmod 640 "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
    echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Beginning run-scheduled-duplicacy-backup.bash version $VERSION" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"

    # Test internet connectivity
    i=0
    while test "$i" -lt 5 && ! wget -q --spider http://www.google.com/; do
        sleep 5
        let "i++"
    done

    kbyte_limit=""
    if [ "${RATE_LIMIT_IP}" ]; then
        if /sbin/ip addr show | grep "inet ${RATE_LIMIT_IP}"; then
            # This host should be ratelimited
            if [ "${RATE_LIMIT_RATE}" ]; then
                kbyte_limit="-limit-rate ${RATE_LIMIT_RATE}"
            else
                kbyte_limit="-limit-rate 32"
            fi
        fi
    fi
    KEY_FILE="`readlink -f ${DUPLICACY_BASEDIR}/keys/id_*_$(hostname --short)`"
    KNOWN_HOSTS=${DUPLICACY_BASEDIR}/keys/known_hosts

    # Tell healtchecks.io to start
    curl --fail --silent --show-error --retry 3 https://hc-ping.com/${HC_UUID}/start

    # Enter backup directory
    for backup_directory in "${BACKUP_DIRECTORIES[@]}"; do
        cd "$backup_directory" || exit 1

        # NOTE : We presume that each backup directory is only configured to backup to one destination

        storage_destination=$(python3 -c "import sys, json; print(json.load(sys.stdin)[0]['storage'])" < ".duplicacy/preferences")
        if [[ ${storage_destination} == sftp* ]]; then
            # Parse the duplicacy .preferences file to extract the storage URI and it's components, setting the CLIENT SERVER and SERVER_PORT of the storage destination
            read -r CLIENT SERVER SERVER_PORT <<<$(python3 -c "import sys, json, urllib.parse; d=urllib.parse.urlparse(json.load(sys.stdin)[0]['storage']); print(' '.join(list(map(lambda x: str(getattr(d, x) or 22), ['username', 'hostname', 'port'] ))))" < ".duplicacy/preferences")
            if [ -z "$CLIENT" ] || [ -z "$SERVER" ] || [ -z "$SERVER_PORT" ]; then
                echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Unable to parse sftp servers from duplicacy preferences" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
                exit 1
            fi

            # Test sftp connectivity
            if ! echo "pwd" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER} >/dev/null 2>&1; then
                echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Unable to connect to ${CLIENT}@${SERVER} over sftp Aborting" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
                curl --fail --silent --show-error --retry 3 --data-raw "Unable to connect to ${CLIENT}@${SERVER} over sftp Aborting" https://hc-ping.com/${HC_UUID}/fail
                RUN_FAILED=True
                exit 1
            fi

            # Assess remote backup destination to determine if we have permissions to initiate a prune later
            directory_info=$(echo -e "ls -ln" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER} 2>&1 | awk '$9 == "backup" {print $1" "$3" "$4}')
            DIRECTORY_GROUP="${directory_info##* }"
            DIRECTORY_OWNER="${directory_info#* }"; DIRECTORY_OWNER="${DIRECTORY_OWNER% *}"
            DIRECTORY_MODE="${directory_info%% *}"
            if [ -z "$DIRECTORY_OWNER" ]; then
                echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Unable to determine owner of directory on server" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
            fi
        else
            # Assume if the destination isn't sftp it's a local directory
            # Assume we have permissions to prune if the destination is local because we're root
            DIRECTORY_OWNER=-1  # We just need to set this to a non-zero value

        fi

        # Log backup directory contents
        shopt -s dotglob
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Listing backup targets for ${backup_directory}" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
        for filename in *; do
          echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Backup targets : ${filename} -> $(readlink -f "$filename")" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
        done
        shopt -u dotglob

        echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Beginning backup of ${backup_directory} : duplicacy -log backup -stats ${kbyte_limit}" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"

        # Begin the backup
        ${DUPLICACY_BASEDIR}/bin/duplicacy -log backup -stats ${kbyte_limit} | tee -a ${log_file}
        # Test the exit code of duplicacy using PIPESTATUS (instead of testing the exit code of tee)
        if [ "${PIPESTATUS[0]}" != 0 ]; then
            curl --fail --silent --show-error --retry 3 --data-raw "Backup of ${backup_directory} failed. Duplicacy returned a non-zero exit-code" https://hc-ping.com/${HC_UUID}/fail
            RUN_FAILED=True
            echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Backup of ${backup_directory} failed" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
        else
            echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Backup of ${backup_directory} succeeded" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
            if [ "$DIRECTORY_OWNER" ] && [ "$DIRECTORY_OWNER" != "0" ]; then
                duplicacy_prune
            else
                echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Skipping prune of ${backup_directory} as data on server is owned by root" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
            fi
        fi
    done

    # Upload the logs
    i=0
    while test "$i" -lt 5 && ! wget -q --spider http://www.google.com/; do
        sleep 5
        let "i++"
    done

    if [ -n "$SERVER" ]; then
        # Upload the logs to the last sftp server in the BACKUP_DIRECTORIES list if there is one
        upload_command="put \"${log_file}\" backup/logs/"
        if [ "$DIRECTORY_OWNER" -a "$DIRECTORY_OWNER" != "0" ]; then
            # If we have permission to modify things, then update the symlink pointing to the latest log
            upload_command="${upload_command}\nrm \"backup/logs/duplicacy.$(hostname --short).latest.txt\"\nsymlink \"${log_file_name}\" \"backup/logs/duplicacy.$(hostname --short).latest.txt\""
        fi
        echo -e "${upload_command}" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER} 2>&1 && rm --force --verbose "${log_file}"
    fi
    if [ "$RUN_FAILED" != "True" ]; then
        curl --fail --silent --show-error --retry 3 https://hc-ping.com/${HC_UUID}
    fi
    echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Run complete, log uploaded to the server" | tee -a "${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.txt"
) 200>/var/lock/duplicacy-backup >>${LOG_BASEDIR}/duplicacy.${CLIENT_INDIVIDUAL_ID}.lastrun.txt
