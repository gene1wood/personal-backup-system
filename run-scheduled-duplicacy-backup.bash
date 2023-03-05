#!/bin/bash

# Install this file in /opt/duplicacy/bin/run-scheduled-duplicacy-backup.bash

. /opt/duplicacy/bin/config.bash
if [ -z "${SERVER}" -o -z "${SERVER_PORT}" ]; then
    echo "Config isn't set. Aborting"
    echo 1
fi
DUPLICACY_BASEDIR=/opt/duplicacy
LOG_BASEDIR="${DUPLICACY_BASEDIR}/logs"
CLIENT="`hostname --short`"

(
    flock -n 200 || exit 1

    >${LOG_BASEDIR}/duplicacy.${CLIENT}.lastrun.txt

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
    log_file_name="duplicacy.${CLIENT}.`date +%Y%m%d%H%M%S`.txt"
    log_file="${LOG_BASEDIR}/${log_file_name}"
    echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Beginning backup : duplicacy -log backup -stats ${kbyte_limit}" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
    if ! ${DUPLICACY_BASEDIR}/bin/duplicacy -log backup -stats ${kbyte_limit} | tee -a ${log_file}; then
        curl --fail --silent --show-error --retry 3 https://hc-ping.com/${hc_uuid}/fail
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Backup failed" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
    else
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Backup succeeded" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
        echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Beginning prune : duplicacy -log prune -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
        if ! ${DUPLICACY_BASEDIR}/bin/duplicacy -log prune -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7 |tee -a ${log_file}; then
            # TODO : Decide if we should put a -threads argument in the prune
            curl --fail --silent --show-error --retry 3 https://hc-ping.com/${hc_uuid}/fail
            echo "`date +"%Y-%m-%d %H:%M:%S.000"` ERROR PARENT_UPDATE Prune failed" | tee -a "${log_file}" "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
        else
            curl --fail --silent --show-error --retry 3 https://hc-ping.com/${hc_uuid}
            echo "`date +"%Y-%m-%d %H:%M:%S.000"` INFO PARENT_UPDATE Prune succeeded" | tee -a "${log_file}" >> "${LOG_BASEDIR}/duplicacy.${CLIENT}.txt"
        fi
    fi
    i=0
    while test "$i" -lt 5 && ! wget -q --spider http://www.google.com/; do
        sleep 5
        let "i++"
    done
    echo -e "put \"${log_file}\" backup/logs/\nrm \"backup/logs/duplicacy.${CLIENT}.latest.txt\"\nsymlink \"${log_file_name}\" \"backup/logs/duplicacy.${CLIENT}.latest.txt\"" | sftp -o Port=${SERVER_PORT} -o IdentityFile=${KEY_FILE} -o BatchMode=yes -o UserKnownHostsFile=${KNOWN_HOSTS} ${CLIENT}@${SERVER} 2>&1 && rm --force --verbose "${log_file}"
) 200>/var/lock/duplicacy-backup >>${LOG_BASEDIR}/duplicacy.${CLIENT}.lastrun.txt
