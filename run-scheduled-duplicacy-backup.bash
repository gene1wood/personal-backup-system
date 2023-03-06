#!/bin/bash

# Install this file in /opt/duplicacy/bin/run-scheduled-duplicacy-backup.bash

VERSION=1.0.1
. /opt/duplicacy/bin/config.bash
if [ -z "${SERVER}" -o -z "${SERVER_PORT}" ]; then
    echo "Config isn't set. Aborting"
    exit 1
fi
DUPLICACY_BASEDIR=/opt/duplicacy
LOG_BASEDIR="${DUPLICACY_BASEDIR}/logs"
CLIENT="`hostname --short`"

duplicacy_prune () {
    echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Beginning prune : duplicacy -log prune -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
    if ! ${DUPLICACY_BASEDIR}/bin/duplicacy -log prune -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7 |tee -a ${log_file}; then
        # TODO : Decide if we should put a -threads argument in the prune
        curl --fail --silent --show-error --retry 3 https://hc-ping.com/${hc_uuid}/fail
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Prune failed" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
    else
        curl --fail --silent --show-error --retry 3 https://hc-ping.com/${hc_uuid}
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Prune succeeded" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
    fi
}

(
    flock -n 200 || exit 1

    >${LOG_BASEDIR}/duplicacy.${CLIENT}.lastrun.txt

    log_file_name="duplicacy.${CLIENT}.`date +%Y%m%d%H%M%S`.txt"
    log_file="${LOG_BASEDIR}/${log_file_name}"
    echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Beginning run-scheduled-duplicacy-backup-secure.bash version $VERSION" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"

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
    KEY_FILE="`readlink -f ${DUPLICACY_BASEDIR}/keys/id_*_${CLIENT}`"
    KNOWN_HOSTS=${DUPLICACY_BASEDIR}/keys/known_hosts
    if ! test -e ${DUPLICACY_BASEDIR}/hc_uuid; then
        echo "get hc_uuid ${DUPLICACY_BASEDIR}/" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER} 2>&1
    fi
    hc_uuid="`cat ${DUPLICACY_BASEDIR}/hc_uuid`"
    curl --fail --silent --show-error --retry 3 https://hc-ping.com/${hc_uuid}/start
    cd ${DUPLICACY_BASEDIR}/backup

    shopt -s dotglob
    for filename in *; do
      echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Backup targets : ${filename} -> $(readlink -f "$filename")" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
    done
    shopt -u dotglob

    echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Beginning backup : duplicacy -log backup -stats ${kbyte_limit}" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"

    directory_info=$(echo -e "ls -ln" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER} 2>&1 | awk '$9 == "backup" {print $1" "$3" "$4}')
    DIRECTORY_GROUP="${directory_info##* }"
    DIRECTORY_OWNER="${directory_info#* }"; DIRECTORY_OWNER="${DIRECTORY_OWNER% *}"
    DIRECTORY_MODE="${directory_info%% *}"
    if [ -z "$DIRECTORY_OWNER" ]; then
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Unable to determine owner of directory on server" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
    fi
    if ! ${DUPLICACY_BASEDIR}/bin/duplicacy -log backup -stats ${kbyte_limit} | tee -a ${log_file}; then
        curl --fail --silent --show-error --retry 3 https://hc-ping.com/${hc_uuid}/fail
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Backup failed" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
    else
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Backup succeeded" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
        if [ "$DIRECTORY_OWNER" -a "$DIRECTORY_OWNER" != "0" ]; then
            duplicacy_prune
        else
            echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Skipping prune as data on server is owned by root" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
        fi
    fi
    i=0
    while test "$i" -lt 5 && ! wget -q --spider http://www.google.com/; do
        sleep 5
        let "i++"
    done
    upload_command="put \"${log_file}\" backup/logs/"
    if [ "$DIRECTORY_OWNER" -a "$DIRECTORY_OWNER" != "0" ]; then
        # If we have permission to modify things, then update the symlink pointing to the latest log
        upload_command="${upload_command}\nrm \"backup/logs/duplicacy.${CLIENT}.latest.txt\"\nsymlink \"${log_file_name}\" \"backup/logs/duplicacy.${CLIENT}.latest.txt\""
    fi
    echo -e "${upload_command}" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER} 2>&1 && rm --force --verbose "${log_file}"
    echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Run complete, log uploaded to the server" | tee -a "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
) 200>/var/lock/duplicacy-backup >>${LOG_BASEDIR}/duplicacy.${CLIENT}.lastrun.txt
