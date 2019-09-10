#!/bin/bash

set -e
XRAY_USER_NAME=${XRAY_USER_NAME:-"xray"}
XRAY_USER_GROUP=${XRAY_USER_GROUP:-"xray"}
# PREREQUISITES
DOCKER_SERVER_MIN_VER='1.11'
#DOCKER_SERVER_CURRENT_VER, this should be passed by the installer script [xray.sh] as $(docker version --format '{{.Server.Version}}') || DOCKER_SERVER_CURRENT_VER=""

MAX_OPEN_FILES_MIN_VALUE=10000
MAX_OPEN_FILES_REQUIRED_VALUE=32000

# XRAY_APP_SERVICES_LIST, the services names as they are in the docker-cmpose file, SPACE separated
XRAY_APP_SERVICES_LIST="xray-server xray-indexer xray-analysis xray-persist"

# PREREQUISITES
DOCKER_SERVER_MIN_VER='1.11'
#DOCKER_SERVER_CURRENT_VER, this should be passed by the installer script [xray.sh] as $(docker version --format '{{.Server.Version}}') || DOCKER_SERVER_CURRENT_VER=""

RECOMMENDED_MIN_RAM=8388608     # it means that for Xray need more than 8G Total RAM => 8*1024*1024k=8388608
RECOMMENDED_MAX_USED_STORAGE=80  # it means that for Xray need more than 20% available storage
RECOMMENDED_MIN_CPU=4
CANCEL_INSTALLER_STATE=false
VALID_USER_CHOICE=false

XRAY_CONFIG_FILE_TEMPLATE="/opt/jfrog/xray/xray-installer/xray_config.yml.template"

INSTALLER_INFO_FILE="/data/installer.info"
DEPLOYED="deployed"
RABBIT_CONNECTION_STRING_DEFAULT='amqp://guest:guest@rabbitmq:5672'
MONGO_CONNECTION_STRING_DEFAULT='mongodb://xray:password@mongodb:27017/?authSource=xray&authMechanism=SCRAM-SHA-1'
POSTGRES_CONNECTION_STRING_DEFAULT='postgres://xray:xray@postgres:5432/xraydb?sslmode=disable'
MONGO_KEY='mongoUrl'
POSTGRES_KEY='postgresqlUrl'
RABBIT_KEY='mqBaseUrl'
RABBITMQ_ERLANG_COOKIE_CONTENT=${RABBITMQ_ERLANG_COOKIE_CONTENT:-JFXR_RABBITMQ_COOKIE}

aparse()
{
    if [ ! -z $1 ]; then
        command=$1
        shift
    else
        command=usage
        return 0
    fi

    while [[ $# > 0 ]] ; do
      case "$1" in
        --compose-flags)
            shift
              export DOCKER_COMPOSE_FLAGS=${1}
              shift
          ;;
        --server-flags)
              shift
              export DOCKER_COMPOSE_XRAY_SERVER_FLAGS=${1}
              shift
          ;;
        --persist-flags)
              shift
              export DOCKER_COMPOSE_XRAY_PERSIST_FLAGS=${1}
              shift
          ;;
        --indexer-flags)
              shift
              export DOCKER_COMPOSE_XRAY_INDEXER_FLAGS=${1}
              shift
          ;;
        --analysis-flags)
              shift
              export DOCKER_COMPOSE_XRAY_ANALYSIS_FLAGS=${1}
              shift
          ;;
          *)
              ALL_ARGS="${ALL_ARGS}${1} "
              shift
          ;;
      esac
    done
}

if [ -z "$COMPOSE_PROJECT_NAME" ]; then
    COMPOSE_PROJECT_NAME="xray"
fi

# Installed version
INSTALLER_DATA_FOLDER="/data"
INSTALLED_VERSION_FILE="${INSTALLER_DATA_FOLDER}/version.current"
INSTALLED_VERSION_FILE_HISTORY="${INSTALLER_DATA_FOLDER}/version.history"
INSTALLED_VERSION=''
EULA_DOC="${INSTALLER_DATA_FOLDER}/JFrog_Xray_EULA.info"
EULA_DOC_SRC="/opt/jfrog/xray/xray-installer/JFrog_Xray_EULA.info"
XRAY_GLOBAL_MOUNT_ROOT="/xray_global_mount_root" # This should not be used, unless special maintenance is needed
XRAY_CONFIG_FILE="${XRAY_GLOBAL_MOUNT_ROOT}/xray/config/xray_config.yaml"
XRAY_CONFIG_DIR=$(dirname "${XRAY_CONFIG_FILE}")
VALUES_YML="/opt/jfrog/xray/xray-installer/values.yml"
DOCKER_COMPOSE_GENERATED_FILE="/opt/jfrog/xray/xray-installer/docker-compose.yml"
RABBITMQ_ROOT_DATA_DIR="${XRAY_GLOBAL_MOUNT_ROOT}/rabbitmq/mnesia"
RABBITMQ_DB_DATA_DIR="${RABBITMQ_ROOT_DATA_DIR}/rabbit@${DOCKER_SERVER_HOSTNAME}"
RABBITMQ_DEFS_FILE="${RABBITMQ_ROOT_DATA_DIR}/rabbit.definitions.json"
XRAY_SECURITY_DIR="${XRAY_GLOBAL_MOUNT_ROOT}/xray/security"
XRAY_HA_DIR="${XRAY_GLOBAL_MOUNT_ROOT}/xray/ha"
XRAY_MASTER_KEY_FILE="${XRAY_SECURITY_DIR}/master.key"
XRAY_HA_NODE_PROPS_FILE="${XRAY_HA_DIR}/ha-node.properties"

if [ -f $INSTALLED_VERSION_FILE ]
then
    INSTALLED_VERSION=$(cat $INSTALLED_VERSION_FILE)
fi

# Maintainer / Installer version
MAINTAINER_VERSION_FILE="/opt/jfrog/xray/xray-installer/version.current"
MAINTAINER_VERSION=''
if [ -f $MAINTAINER_VERSION_FILE ]
then
    MAINTAINER_VERSION=$(cat $MAINTAINER_VERSION_FILE)
fi

#load xray configuration
XRAY_SERVER_PORT_DEFAULT=8000
XRAY_SERVER_PORT=$(python getXrayConfValue.py -f "${XRAY_CONFIG_FILE}" -k "XrayServerPort" 2>/dev/null ) || echo "XrayServerPort cannot be loaded from xray_config.yaml. Using default value: ${XRAY_SERVER_PORT_DEFAULT}"
XRAY_SERVER_PORT=${XRAY_SERVER_PORT:-${XRAY_SERVER_PORT_DEFAULT}}
re_is_num='^[0-9]+$'
if ! [[ $XRAY_SERVER_PORT =~ $re_is_num ]] ; then
   echo "ERROR: xray_config.yaml: XrayServerPort is not a number" >&2; exit 1
fi

# Default compose env
export XRAY_SERVER_PORT=${XRAY_SERVER_PORT}
export XRAY_DATA="/var/opt/jfrog/xray/data"
export DOCKER_COMPOSE_FLAGS=''
export DOCKER_COMPOSE_XRAY_SERVER_FLAGS=''
export DOCKER_COMPOSE_XRAY_PERSIST_FLAGS=''
export DOCKER_COMPOSE_XRAY_INDEXER_FLAGS=''
export DOCKER_COMPOSE_XRAY_ANALYSIS_FLAGS=''

exitOnError()
{
    msg=$1
    echo "ERROR: ${msg}"
    exit 1
}

usage() {
    cat ./readme.txt
    exit 1
}

version_lt() { test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1"; }

# $1 should be WARNING or ERROR
printUlimitErrorMsg()
{
    local error_level=$1
    local number=$2
    MSG="
${error_level}: Max number of open files [${number}] is too low !!!

Add the following to /etc/security/limits.conf file on HOST:
* soft nofile ${MAX_OPEN_FILES_REQUIRED_VALUE}
* hard nofile ${MAX_OPEN_FILES_REQUIRED_VALUE}

Note: Also verify docker limits configuration if exists [usually in /etc/default/docker]

"

    case ${error_level} in
    "ERROR")
        echo -e "\033[31m${MSG}\033[0m "
    ;;
    "WARNING")
        echo -e "\033[33m${MSG}\033[0m"
    ;;
    esac

    echo
}

userChoiceVerification() {
    if [[ "$1" = [nN] ]] || [[ "$1" = [yY] ]]; then
        VALID_USER_CHOICE=true
    else
        echo "Invalid option."
    fi;
}

checkPrerequisites()
{
    #echo "Check dependencies:"
    echo "Verifying Xray pre-requisites ..."
    TOTAL_RAM="$(grep ^MemTotal /proc/meminfo | awk '{print $2}')"
    USED_STORAGE="$(df -h /data | tail -n +2 | tr -s ' ' | tr '%' ' ' | cut -d ' ' -f 5)"
    FREE_CPU="$(grep -c ^processor /proc/cpuinfo)"
    local msg=""

    if [ -z ${DOCKER_SERVER_CURRENT_VER} ] || [ "${DOCKER_SERVER_CURRENT_VER}" == "" ]
    then
        msg="WARNING: Docker daemon version is unknown"
        echo -e "\033[33m${msg}\033[0m"
        CANCEL_INSTALLER_STATE=true
        # Do not exit on warning
    fi

    if version_lt ${DOCKER_SERVER_CURRENT_VER} ${DOCKER_SERVER_MIN_VER}
    then
        echo ""
        exitOnError "Xray requires Docker daemon version ${DOCKER_SERVER_MIN_VER} or later. The current version is ${DOCKER_SERVER_CURRENT_VER}."
    fi

    # echo "Check max number of open files:"
    currentMaxOpenFilesVal=$(ulimit -n)

    if [ "${currentMaxOpenFilesVal}" != "unlimited" ] ; then

        # MAX_OPEN_FILES_REQUIRED_VALUE
        if [ ${currentMaxOpenFilesVal} -lt ${MAX_OPEN_FILES_REQUIRED_VALUE} ]
        then
            #echo "Trying to set max open files = ${MAX_OPEN_FILES_REQUIRED_VALUE}"
            ulimit -n ${MAX_OPEN_FILES_REQUIRED_VALUE} 2>/dev/null
            if [ $? -gt 0 ]
            then
                # Cannot set MAX_OPEN_FILES_REQUIRED_VALUE, will try to set MAX_OPEN_FILES_MIN_VALUE
                # MAX_OPEN_FILES_MIN_VALUE
                if [ ${currentMaxOpenFilesVal} -lt ${MAX_OPEN_FILES_MIN_VALUE} ]
                then
                    #echo "Trying to set max open files = ${MAX_OPEN_FILES_MIN_VALUE}"
                    ulimit -n ${MAX_OPEN_FILES_MIN_VALUE} 2>/dev/null
                    if [ $? -gt 0 ]; then
                        printUlimitErrorMsg "ERROR" "${currentMaxOpenFilesVal}"
                        return 1
                    fi
                fi
                printUlimitErrorMsg "WARNING" "${currentMaxOpenFilesVal}"
                CANCEL_INSTALLER_STATE=true
                # Do not exit on warning
            fi
        fi

    fi

    #Checking RAM
    if [[ ${TOTAL_RAM} -lt ${RECOMMENDED_MIN_RAM} ]]; then
        let "TOTAL_RAM_TO_SHOW = ${TOTAL_RAM} / 1024 / 1024"
        msg="WARNING: Running with ${TOTAL_RAM_TO_SHOW}GB Total RAM"
        echo -e "\033[33m${msg}\033[0m"
        CANCEL_INSTALLER_STATE=true
    fi;
    #Checking disk space
    if [[ ${USED_STORAGE} -gt ${RECOMMENDED_MAX_USED_STORAGE} ]]; then
        let "AVAILABLE_STORAGE = 100 - ${USED_STORAGE}"
        msg="WARNING: Running with $AVAILABLE_STORAGE% Free Storage"
        echo -e "\033[33m${msg}\033[0m"
        CANCEL_INSTALLER_STATE=true
    fi;

    #Checking cpu
    if [ ${FREE_CPU} -lt ${RECOMMENDED_MIN_CPU} ]; then
        msg="WARNING: Running with $FREE_CPU CPU Cores"
        echo -e "\033[33m${msg}\033[0m"
        CANCEL_INSTALLER_STATE=true
    fi;

    #Asking user to proceed or not
    if [ "${USE_DEFAULTS}" == false ]; then
        if [ ${CANCEL_INSTALLER_STATE} != "false" ]; then
            until [ ${VALID_USER_CHOICE} == true ]; do
                 #read -p "The System resources are not aligned with Xray minimal pre-requisites, Do you want to proceed with the process? [Y/N]: " USER_CHOICE
                 USER_CHOICE=y
                 userChoiceVerification ${USER_CHOICE}
            done
        fi
    else
        USER_CHOICE=y
    fi

    #In case that user typed "nN", exiting"
    if [[ "${USER_CHOICE}" =~ [nN] ]]; then
        echo "Exiting..."
        exit 1
    fi;

    # dependencies check is passed
    return 0
}


# Do the actual permission check and chown
checkAndSetOwnerOnDir () {
    local DIR_TO_CHECK=$1
    local USER_TO_CHECK=$2
    local GROUP_TO_CHECK=$3

    logger "Checking permissions on $DIR_TO_CHECK"
    local STAT=( $(stat -Lc "%U %G" ${DIR_TO_CHECK}) )
    local USER=${STAT[0]}
    local GROUP=${STAT[1]}

    if [[ ${USER} != "$USER_TO_CHECK" ]] || [[ ${GROUP} != "$GROUP_TO_CHECK"  ]] ; then
        logger "$DIR_TO_CHECK is owned by $USER:$GROUP. Setting to $USER_TO_CHECK:$GROUP_TO_CHECK."
        chown -R ${USER_TO_CHECK}:${GROUP_TO_CHECK} ${DIR_TO_CHECK} || exitOnError "Setting ownership on $DIR_TO_CHECK failed"
    else
        logger "$DIR_TO_CHECK is already owned by $USER_TO_CHECK:$GROUP_TO_CHECK."
    fi
}

# Creating Xray config dir and setting xray user permissions on files
setupDirsPermissions () {

    local installer_mount_root="${INSTALLER_DATA_FOLDER}"
    local xray_mount_root="${XRAY_GLOBAL_MOUNT_ROOT}/xray"
    echo "Checking permissions on ${XRAY_MOUNT_ROOT} on host"
    chown -R ${XRAY_USER_NAME}:${XRAY_USER_GROUP} ${installer_mount_root} || exitOnError "Setting ownership on ${XRAY_MOUNT_ROOT}/xray-installer : ${installer_mount_root} (on the host : inside the container) failed "

    # xray_global_mount_root in the container is equivalent to XRAY_MOUNT_ROOT on the host
    STAT=( $(stat -c "%U %G" ${xray_mount_root}) )
    USER=${STAT[0]}
    GROUP=${STAT[1]}

    if [[ ${USER} != "$XRAY_USER_NAME" ]] || [[ ${GROUP} != "$XRAY_USER_GROUP"  ]] ; then
         echo "$XRAY_MOUNT_ROOT is owned by $USER:$GROUP. Setting to $XRAY_USER_NAME:$XRAY_USER_GROUP."
         echo "NOTE: The following procedures change the ownership of files and may take several minutes. Do not stop the installation/upgrade process."
         chown -R ${XRAY_USER_NAME}:${XRAY_USER_GROUP} ${xray_mount_root} || exitOnError "Setting ownership on ${XRAY_MOUNT_ROOT}/xray : ${xray_mount_root} (on the host : inside the container) failed "
    else
        echo "$XRAY_MOUNT_ROOT is already owned by $XRAY_USER_NAME:$XRAY_USER_GROUP."
    fi
}

dockerLogin() {
    if [ ! -z ${XRAY_DOCKER_USERNAME} ] && [ ! -z ${XRAY_DOCKER_PASSWORD} ]; then
        docker login -u ${XRAY_DOCKER_USERNAME} -p ${XRAY_DOCKER_PASSWORD} ${XRAYDB_DOCKER_REPO}
        docker login -u ${XRAY_DOCKER_USERNAME} -p ${XRAY_DOCKER_PASSWORD} ${XRAY_DOCKER_REPO}
    fi

}


runDockerCommand() {
    local action=$1

    case $action in
    "pull")
       if  [ "$DOCKER_INSTALLER_OFFLINE" == "true" ]; then
            return 0;
       else
            dockerLogin
       fi
    ;;
    "logs")
        action="logs -f"
    ;;
    "stopApp")
        # Stop Xray App layer
        docker-compose -p ${COMPOSE_PROJECT_NAME} "stop" ${XRAY_APP_SERVICES_LIST}
        return $?
    ;;
    "restart")
        docker-compose -p ${COMPOSE_PROJECT_NAME} "stop"
        sleep 3
        action="up -d --remove-orphans"
    ;;
    "restartApp")
        # Restart Xray App Layer
        docker-compose -p ${COMPOSE_PROJECT_NAME} "stop" ${XRAY_APP_SERVICES_LIST}
        sleep 3
        action="up -d --remove-orphans"
    ;;
    esac

    docker-compose -p ${COMPOSE_PROJECT_NAME} ${action}
}

# Returned code:
#0) $1=$2
#1) $1>$2
#2) $1<$2
verComp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i
    local ver1=($1)
    local ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

isUpgradeAllowed() {

    local installedVersion=$INSTALLED_VERSION
    local maintainerVersion=$MAINTAINER_VERSION

    if [ -z $MAINTAINER_VERSION ]
    then
        exitOnError "MAINTAINER_VERSION is unknown"
    fi

    # This is a fresh installation
    if [ -z $INSTALLED_VERSION ]
    then
        return 0
    fi

    if [[ "$installedVersion" =~ ^b.* ]] && [[ "$maintainerVersion" =~ ^b.* ]]
    then
        installedVersion=($(echo $INSTALLED_VERSION | sed "s/^b//g"))
        maintainerVersion=($(echo $MAINTAINER_VERSION | sed "s/^b//g"))
    fi

    verComp $installedVersion $maintainerVersion 2>/dev/null
    if [ $? -eq 1 ]
    then
        return 1
    fi

    return 0
}

isCommandAllowed()
{
    local command=$1
    local installedVersion=$INSTALLED_VERSION
    local maintainerVersion=$MAINTAINER_VERSION

    case ${command} in
        "install")
            [ -f $INSTALLED_VERSION_FILE ] && exitOnError "Xray is already installed. To upgrade, use: ./xray upgrade"
            checkPrerequisites || exitOnError "Pre-requisites are not satisfied"
        ;;
        "upgrade")
            [ -f $INSTALLED_VERSION_FILE ] || exitOnError "Xray is not installed. To install, use: ./xray install"
            checkPrerequisites || exitOnError "Pre-requisites are not satisfied"
            isUpgradeAllowed || exitOnError "Unable to upgrade to an older version"
        ;;
        "version")

        ;;
        "info")

        ;;
        *)
            # Is installed
            [ -f $INSTALLED_VERSION_FILE ] || exitOnError "Xray is not installed. To install, use: ./xray install"
            # Is correct version
            [ "${installedVersion}" == "${maintainerVersion}" ] || exitOnError "You are using the Xray installer version [${maintainerVersion}] which is different from the currently installed version [${installedVersion}]. Consider upgrading your version of Xray using: ./xray upgrade"
        ;;

    esac

    return 0
}

setVersions(){

    if [ ! -f ${MAINTAINER_VERSION_FILE} ]
    then
        return 1
    fi

    cat ${MAINTAINER_VERSION_FILE} > ${INSTALLED_VERSION_FILE}
    cat ${MAINTAINER_VERSION_FILE} >> ${INSTALLED_VERSION_FILE_HISTORY}

    echo "${INSTALLED_VERSION_FILE}: $(cat ${INSTALLED_VERSION_FILE})"

    return 0
}

setEULA(){
    cp ${EULA_DOC_SRC} ${EULA_DOC}
    return $?
}

createMongoUsers(){
    if [ -f ${INSTALLER_INFO_FILE} ]; then
        source ${INSTALLER_INFO_FILE}
    fi
    if [[ "${INSTALL_MONGO}" = [yY] ]]; then
        USERS_CREATED_FILE="${INSTALLER_DATA_FOLDER}/mongo_users.created"
        if [ ! -f "${USERS_CREATED_FILE}" ];then
          sleep 1
          cat createMongoUsers.js | docker exec -i "${COMPOSE_PROJECT_NAME}_mongodb_1" mongo  > /dev/null && \
          touch $USERS_CREATED_FILE || exitOnError "Failed to create MongoDB default users"
        fi
    fi
}

# backward compatible issues
# Xray should be stopped before this process
backwardCmpatibleProcess()
{
    #echo -e "\nINFO: Backward compatible process"
    LOGS_FOLDER_V1="${XRAY_GLOBAL_MOUNT_ROOT}/xray/log"
    LOGS_FOLDER_V2="${XRAY_GLOBAL_MOUNT_ROOT}/xray/logs"
    CONFIG_FOLDER="${XRAY_GLOBAL_MOUNT_ROOT}/xray/config"
    ARCHIVE_FOLDER="${INSTALLER_DATA_FOLDER}/archive"
    TIMESTAMP=$(date +"%s")

    # Rename log folder to be logs
    if [ -d "${LOGS_FOLDER_V1}" ] && [ ! -d "${LOGS_FOLDER_V2}" ]
    then
        mv ${LOGS_FOLDER_V1} ${LOGS_FOLDER_V2} && \
        echo "Logs folder renamed was:[${LOGS_FOLDER_V1}] new:[${LOGS_FOLDER_V2}]"

        # Archive old log4go_config.xml
        if [ ! -d ${ARCHIVE_FOLDER} ]; then
            mkdir -p ${ARCHIVE_FOLDER} && \
            echo "Archive folder was created [${ARCHIVE_FOLDER}]"
        fi

        for log4goService in "analysis" "indexer" "persist" "server"
        do
           echo "Archive ${log4goService}_log4go_config.xml to ${ARCHIVE_FOLDER}"
           if [ -f "${CONFIG_FOLDER}/${log4goService}_log4go_config.xml" ] && [ -d "${ARCHIVE_FOLDER}" ]
           then
                mv "${CONFIG_FOLDER}/${log4goService}_log4go_config.xml" "${ARCHIVE_FOLDER}/${log4goService}_log4go_config.xml.${TIMESTAMP}"
           fi
        done
    fi
}

setClusterConfig() {
    if [ -f ${INSTALLER_INFO_FILE} ]; then
        source ${INSTALLER_INFO_FILE}
    else
        touch ${INSTALLER_INFO_FILE}
    fi

    if [ -z ${HA_INSTALLATION} ]; then
        if [ "${USE_DEFAULTS}" == true ] ; then
            # Force standalone installation in case of "use defaults" mode and no input from INSTALLER_INFO_FILE
            HA_INSTALLATION=false
        else
            VALID_USER_CHOICE=false
            until [ ${VALID_USER_CHOICE} == true ]; do
                #read -p "Are you adding this node to an existing cluster? (not relevant for the first cluster node) [Y/n]: " is_ha_installation
                is_ha_installation=n
                userChoiceVerification ${is_ha_installation}
            done
            if [[ "${is_ha_installation}" = [yY] ]]; then
                HA_INSTALLATION=true
            fi
        fi
    fi

    if [[ "${HA_INSTALLATION}" == true ]];
    then

        if [[ ! -f ${XRAY_MASTER_KEY_FILE} ]];
        then
            until [[ ! -z ${XRAY_MASTER_KEY} ]] && [[ ${XRAY_MASTER_KEY} =~ ^[A-Za-z0-9]{64}$ ]]; do
                read -p "Provide the 32 bytes master key from an active cluster node (the key can be found in <XRAY DATA FOLDER>/security/master.key): " XRAY_MASTER_KEY
            done

            mkdir -p ${XRAY_SECURITY_DIR}
            echo -n ${XRAY_MASTER_KEY} > ${XRAY_MASTER_KEY_FILE}
        fi

        if [[ -z ${XRAY_ACTIVE_NODE} ]];
        then
            ret_code=1
            until [[ ${ret_code} == 0 ]]; do
                XRAY_ACTIVE_NODE=
                read -p "Provide the short host name of an active cluster node (to retrieve it use the 'hostname -s' command): " XRAY_ACTIVE_NODE
                check_host_cmd="ping -c 1 ${XRAY_ACTIVE_NODE}"
                eval ${check_host_cmd} > /dev/null
                ret_code=$?
                if [[ ! ${ret_code} == 0 ]]; then
                    echo "Cannot reach node ${XRAY_ACTIVE_NODE}."
                fi
            done
        fi
        # For backward compatibility in case user already have a cluster with an already set .erlang.cookie content
        read -p "Provide custom .erlang.cookie content for RabbitMQ clustering or press enter to use default [JFXR_RABBITMQ_COOKIE]: " RABBITMQ_ERLANG_COOKIE_CONTENT
        RABBITMQ_ERLANG_COOKIE_CONTENT=${RABBITMQ_ERLANG_COOKIE_CONTENT:-JFXR_RABBITMQ_COOKIE}

    else
        XRAY_ACTIVE_NODE=${DOCKER_SERVER_HOSTNAME}
        HA_INSTALLATION=false
    fi

    mkdir -p ${XRAY_HA_DIR}
    sed -i '/name=/d' ${XRAY_HA_NODE_PROPS_FILE} 2>/dev/null
    echo "name=${XRAY_HA_NODE_ID}" >> ${XRAY_HA_NODE_PROPS_FILE}

    sed -i '/.*XRAY_ACTIVE_NODE.*/d' ${INSTALLER_INFO_FILE} 2>/dev/null
    echo "export XRAY_ACTIVE_NODE=${XRAY_ACTIVE_NODE}" >> ${INSTALLER_INFO_FILE}

    sed -i '/.*HA_INSTALLATION.*/d' ${INSTALLER_INFO_FILE} 2>/dev/null
    echo "export HA_INSTALLATION=${HA_INSTALLATION}" >> ${INSTALLER_INFO_FILE}

    sed -i '/.*RABBITMQ_ERLANG_COOKIE.*/d' ${INSTALLER_INFO_FILE} 2>/dev/null
    echo "export RABBITMQ_ERLANG_COOKIE=${RABBITMQ_ERLANG_COOKIE_CONTENT}" >> ${INSTALLER_INFO_FILE}
}

isValidDbConnectionString() {
    local DB_TYPE=$1
    local INPUT_CONNECTION_STRING=$2

    TRIES_NUM=$((TRIES_NUM+1))
    # Validate connection string format
    if [[ "${INPUT_CONNECTION_STRING}" =~ (${DB_TYPE})(:)(\/\/)(.*@)?(.*)(:)([0-9]*)(\/?)(.*) ]]; then
        host="${BASH_REMATCH[5]}"
        port="${BASH_REMATCH[7]}"

        # Validate connectivity to the external DB
        nc -z -w 2 ${host} ${port} 2>/dev/null
        ret_code=$?
        if [ ! ${ret_code} == 0 ]; then
            echo "Can not access host ${host} port ${port}!" 2>/dev/null
            VALID_DB_STR=false
        else
            VALID_DB_STR=true
        fi
    else
        echo "Connection string for ${DB_TYPE} is not valid!"
        VALID_DB_STR=false
    fi

    if [ ${VALID_DB_STR} == false ] && [ "${TRIES_NUM}" -ge ${MAX_TRIES_INSERT_CONNECTION_STR} ]; then
        echo "Too many tries to insert a valid connection string of ${DB_TYPE}!!!"
        if [ "${USE_DEFAULTS}" == true ] ; then
            PROCEED_INSTALLATION=y
        else
            VALID_USER_CHOICE=false
            until [ ${VALID_USER_CHOICE} == true ]; do
                #read -p "Would you like to proceed and fix this later? [Y/n]: " PROCEED_INSTALLATION
                PROCEED_INSTALLATION=Y
                userChoiceVerification ${PROCEED_INSTALLATION}
            done
        fi

        if [[ "${PROCEED_INSTALLATION}" = [nN] ]]; then
            exitOnError
        fi
    fi

    return 0
}

setRabbitCluster() {
    if [ -f ${INSTALLER_INFO_FILE} ]; then
        source ${INSTALLER_INFO_FILE}
    fi

    if [ "${HA_INSTALLATION}" == true ]; then
        logger "Running set RabbitMQ cluster procedure..."
        export XRAY_ACTIVE_NODE=${XRAY_ACTIVE_NODE}
        sed -i 's@${XRAY_ACTIVE_NODE}@'"${XRAY_ACTIVE_NODE}"'@' setRabbitCluster.sh
        chmod +x setRabbitCluster.sh
        docker cp setRabbitCluster.sh "${COMPOSE_PROJECT_NAME}_rabbitmq_1":/tmp/setRabbitCluster.sh
        docker exec -it "${COMPOSE_PROJECT_NAME}_rabbitmq_1" /tmp/setRabbitCluster.sh
    fi
}

#This function is generating "installer.info" file
getThirdpMetadata() {
    if [ ! -f ${XRAY_CONFIG_FILE} ]; then
        MAX_TRIES_INSERT_CONNECTION_STR=3

        # Never allow external rabbit!!!
        INSTALL_RABBIT=y

         if [ "${USE_DEFAULTS}" == true ]; then
            # Force local databases installation in case of "use defaults" mode
            INSTALL_POSTGRES=y
            INSTALL_MONGO=y
         elif [ "${HA_INSTALLATION}" == false ]; then
            VALID_USER_CHOICE=false
            until [ ${VALID_USER_CHOICE} == true ]; do
                #read -p "Would you like to install PostgreSQL instance? [Y/n]: " INSTALL_POSTGRES
                INSTALL_POSTGRES=n
                userChoiceVerification ${INSTALL_POSTGRES}
            done

            VALID_USER_CHOICE=false
            until [ ${VALID_USER_CHOICE} == true ]; do
                #read -p "Would you like to install MongoDB instance? [Y/n]: " INSTALL_MONGO
                INSTALL_MONGO=n
                userChoiceVerification ${INSTALL_MONGO}
            done
        else
            # Force external postgres and mongo in case of HA
            INSTALL_POSTGRES=n
            INSTALL_MONGO=n
        fi

        if [[ "${INSTALL_POSTGRES}" = [nN] ]]; then
            TRIES_NUM=0
            VALID_DB_STR=false
            until [ ${VALID_DB_STR} == true ] || [ "${TRIES_NUM}" -ge ${MAX_TRIES_INSERT_CONNECTION_STR} ]; do
                #read -p "Provide a PostgreSQL connection string [${POSTGRES_CONNECTION_STRING_DEFAULT}]: " POSTGRES_CONNECTION_STRING
                POSTGRES_CONNECTION_STRING=$URL_POSTGRES
                echo 1 $URL_POSTGRES
                echo 1 $POSTGRES_CONNECTION_STRING
                isValidDbConnectionString "postgres" "${POSTGRES_CONNECTION_STRING}"
            done
        fi

        if [[ "${INSTALL_MONGO}" = [nN] ]]; then
            TRIES_NUM=0
            VALID_DB_STR=false
            until [ ${VALID_DB_STR} == true ] || [ "${TRIES_NUM}" -ge ${MAX_TRIES_INSERT_CONNECTION_STR} ]; do
                #read -p "Provide a MongoDB connection string [${MONGO_CONNECTION_STRING_DEFAULT}]: " MONGO_CONNECTION_STRING
                MONGO_CONNECTION_STRING=$URL_MONGO
                echo 2 $URL_MONGO
                echo 2 $MONGO_CONNECTION_STRING
                isValidDbConnectionString "mongodb" "${MONGO_CONNECTION_STRING}"
            done
        fi

        #SETTING VARS IN installer.info
        if [ ! -f ${INSTALLER_INFO_FILE} ]; then
            touch ${INSTALLER_INFO_FILE}
        fi

        sed -i '/.*INSTALL_RABBIT.*/d' ${INSTALLER_INFO_FILE} || echo "There is nothing to delete, skipping ..."
        echo "export INSTALL_RABBIT=${INSTALL_RABBIT}" >> ${INSTALLER_INFO_FILE}

        sed -i '/.*INSTALL_POSTGRES.*/d' ${INSTALLER_INFO_FILE} || echo "There is nothing to delete, skipping ..."
        echo "export INSTALL_POSTGRES=${INSTALL_POSTGRES}" >> ${INSTALLER_INFO_FILE}

        sed -i '/.*POSTGRES_CONNECTION_STRING.*/d' ${INSTALLER_INFO_FILE} || echo "There is nothing to delete, skipping ..."
        echo "export POSTGRES_CONNECTION_STRING=${POSTGRES_CONNECTION_STRING}" >> ${INSTALLER_INFO_FILE}

        sed -i '/.*INSTALL_MONGO.*/d' ${INSTALLER_INFO_FILE} || echo "There is nothing to delete, skipping ..."
        echo "export INSTALL_MONGO=${INSTALL_MONGO}" >> ${INSTALLER_INFO_FILE}

        sed -i '/.*MONGO_CONNECTION_STRING.*/d' ${INSTALLER_INFO_FILE} || echo "There is nothing to delete, skipping ..."
        echo "export MONGO_CONNECTION_STRING=${MONGO_CONNECTION_STRING}" >> ${INSTALLER_INFO_FILE}
    fi
}

#This function replaces values in xray_conf.yml template file
replaceStringByKey() {
    key=$1
    connection_string=$2
    value=$(grep ${key} ${XRAY_CONFIG_FILE} | awk '{print $2}')

    #Replacing & with %% in order to prevent sed issues
    connection_string=$(echo ${connection_string} | sed -e "s|\&|%%|g")
    value=$(echo ${value} | sed -e "s|\&|%%|g")
    sed -e "s|\&|%%|g" -i ${XRAY_CONFIG_FILE}

    #Where choose a non default app AND connection string is still default
    if [ ! "${value}" == "${DEPLOYED}" ]; then
        sed -e "s|${value}|${connection_string}|g" -i ${XRAY_CONFIG_FILE}

    #Replacing %% with & (REVERT)
        sed -e "s|%%|\&|g" -i ${XRAY_CONFIG_FILE}
        connection_string=$(echo ${connection_string} | sed -e "s|%%|\&|g")
        sed --in-place "s|${connection_string}|${DEPLOYED}|g" ${INSTALLER_INFO_FILE}
    fi
}

#This function is generating "xray_conf.yml" file
setValuesXrayConfig() {
    if [ -f ${INSTALLER_INFO_FILE} ]; then
        source ${INSTALLER_INFO_FILE}
    fi
    if [ ! -f ${XRAY_CONFIG_FILE} ]; then
        if [ ! -d ${XRAY_CONFIG_DIR} ] ; then
            mkdir -p ${XRAY_CONFIG_DIR}
        fi
        cp ${XRAY_CONFIG_FILE_TEMPLATE} ${XRAY_CONFIG_FILE}

        if [[ "${INSTALL_POSTGRES}" = [nN] ]]; then
            replaceStringByKey ${POSTGRES_KEY} ${POSTGRES_CONNECTION_STRING}
        fi
        if [[ "${INSTALL_MONGO}" = [nN] ]]; then
            replaceStringByKey ${MONGO_KEY} ${MONGO_CONNECTION_STRING}
        fi
    fi
}

#This function is generating docker-compose.yml and values.yml
generateComposeFile() {
    if [ -f ${DOCKER_COMPOSE_GENERATED_FILE} ]; then
        rm -rf ${DOCKER_COMPOSE_GENERATED_FILE}
    fi

    #Generating values.yml
    if [[ "${INSTALL_POSTGRES}" = [nN] ]]; then
        sed -i '/.*postgres.*/d' ${VALUES_YML} || echo "There is nothing to delete, skipping ..."
        echo "  postgres: false" >> ${VALUES_YML}
    fi
    if [[ "${INSTALL_MONGO}" = [nN] ]]; then
        sed -i '/.*mongodb.*/d' ${VALUES_YML} || echo "There is nothing to delete, skipping ..."
        echo "  mongodb: false" >> ${VALUES_YML}
    fi

    #Generating docker-compose.yml
    python generate-compose-file.py
    if [ $? -gt 0 ]; then
        echo "Error while generating a customized docker-compose.yml, Exiting..."
        return 1
    fi
}

backupRabbitMetadata() {
    # Check the name of the Rabbitmq data directory; Need to backup and restore only if it is not in the format
    if [ ! -d "${RABBITMQ_DB_DATA_DIR}" ]; then

        if [ -z ${DOCKER_SERVER_FQDN} ]; then
            ret_code=1
            until [ ${ret_code} == 0 ]; do
                DOCKER_SERVER_FQDN=
                read -p "RabbitMQ migration needed; Provide ip address or host FQDN of the docker host where the installation is running: " DOCKER_SERVER_FQDN
                check_host_cmd="ping -c 1 ${DOCKER_SERVER_FQDN}"
                eval ${check_host_cmd} > /dev/null
                ret_code=$?
                if [ ! ${ret_code} == 0 ]; then
                    echo "Can not access ${DOCKER_SERVER_FQDN}!!!"
                fi
            done
        fi

        # Check if Rabbit is running; if not - need to start it in order to execute the REST
        docker-compose -f docker-compose-v1.yml -p ${COMPOSE_PROJECT_NAME} up -d rabbitmq || exitOnError "Failed to start Rabbitmq container"
        sleep 10

        RABBITMQ_OLD_HOSTNAME=$(docker exec -i xray_rabbitmq_1 hostname)
        [ ! -z ${RABBITMQ_OLD_HOSTNAME} ] || exitOnError "Failed to retrieve Rabbitmq container hostname"

        curl http://guest:guest@${DOCKER_SERVER_FQDN}:15672/api/definitions -o ${RABBITMQ_DEFS_FILE} > /dev/null 2>&1
        [ -f "${RABBITMQ_DEFS_FILE}" ] || exitOnError "Failed to backup Rabbitmq definitions during upgrade process!!!"

        docker-compose -f docker-compose-v1.yml -p ${COMPOSE_PROJECT_NAME} stop rabbitmq
    fi
}

backupRabbitDataAndRestoreRabbit() {
    if [ ! -d "${RABBITMQ_DB_DATA_DIR}" ]; then
        RABBITMQ_OLD_DB_DATA_DIR="${RABBITMQ_ROOT_DATA_DIR}/rabbit@${RABBITMQ_OLD_HOSTNAME}"

        mkdir -p ${RABBITMQ_DB_DATA_DIR}
        cp -R ${RABBITMQ_OLD_DB_DATA_DIR}/msg_store_* ${RABBITMQ_DB_DATA_DIR} > /dev/null 2>&1 || echo "Couldn't find msg_store directories to copy during Rabbitmq migration process!!!"
        cp -R ${RABBITMQ_OLD_DB_DATA_DIR}/queues ${RABBITMQ_DB_DATA_DIR} > /dev/null 2>&1 || echo "Couldn't find queues directory to copy during Rabbitmq migration process!!!"
        cp ${RABBITMQ_OLD_DB_DATA_DIR}/recovery.dets ${RABBITMQ_DB_DATA_DIR} > /dev/null 2>&1 || echo "Couldn't find recovery.dets to copy during Rabbitmq migration process!!!"

        local STAT=( $(stat -Lc "%u %g" ${RABBITMQ_OLD_DB_DATA_DIR}) )
        local USER=${STAT[0]}
        local GROUP=${STAT[1]}

        checkAndSetOwnerOnDir ${RABBITMQ_DB_DATA_DIR} ${USER} ${GROUP}

        docker-compose -p ${COMPOSE_PROJECT_NAME} up -d rabbitmq || exitOnError "Failed to start Rabbitmq for completing the backup process!!!"
        sleep 10

        docker exec -i xray_rabbitmq_1 rabbitmqctl status > /dev/null 2>&1 || exitOnError "Rabbitmq container is down - cannot complete the backup process!!!"

        curl -X POST -H "Content-Type: application/json" -d @${RABBITMQ_DEFS_FILE} http://guest:guest@${DOCKER_SERVER_FQDN}:15672/api/definitions > /dev/null 2>&1 || exitOnError "Failed to restore Rabbitmq definitions during upgrade process!!!"
        docker-compose -p ${COMPOSE_PROJECT_NAME} stop rabbitmq

        # Remove existing rabbitmq cookie in order to make the rabbitmq HA-ready
        # Will be override by RABBITMQ_ERLANG_COOKIE environment defined in docker-compose.yml
        rm -rf ${XRAY_GLOBAL_MOUNT_ROOT}/rabbitmq/.erlang.cookie
    fi
}

##################################
############## MAIN ##############
##################################

aparse $@

isCommandAllowed ${command}

case $command in
    install)
        ( setClusterConfig && \
          getThirdpMetadata && \
          setValuesXrayConfig && \
          generateComposeFile && \
          runDockerCommand pull && \
          setVersions && \
          setEULA \
          setupDirsPermissions \
        ) || exitOnError "Installation failed"
        echo
        echo -e "\033[32mINFO: Xray $MAINTAINER_VERSION was successfully installed. Run: ./xray start\033[0m"
        echo "To access Xray, browse to http://<server_name>:8000"
        echo "For more information, please refer to the JFrog Xray User Guide: https://www.jfrog.com/confluence/display/XRAY/Welcome+to+JFrog+Xray"
        echo
        echo -e "\033[33mNote: You may want to make 'xray' the owner of Xray files. In order to do that please run the following command on the host:\033[0m"
        echo -e "\033[33mgroupadd -g 1035 xray && useradd -u 1035 -g 1035 -m -s /bin/false xray\033[0m"
        ;;
    upgrade)
        ( setClusterConfig && \
          backupRabbitMetadata && \
          getThirdpMetadata && \
          setValuesXrayConfig && \
          generateComposeFile && \
          runDockerCommand pull && \
          runDockerCommand stopApp && \
          backwardCmpatibleProcess && \
          setVersions && \
          setupDirsPermissions && \
          backupRabbitDataAndRestoreRabbit \
        ) || exitOnError "Upgrade failed"
        echo
        echo "INFO: Xray was successfully upgraded. Run: ./xray start"
        echo ""
        ;;
    start)
        getThirdpMetadata && \
        setValuesXrayConfig && \
        generateComposeFile && \
        runDockerCommand "up -d --remove-orphans" && \
        setRabbitCluster && \
        createMongoUsers && \
        setupDirsPermissions
        ;;
    ps|logs|stop|kill|restart|restartApp)
        getThirdpMetadata && \
        setValuesXrayConfig && \
        generateComposeFile && \
        runDockerCommand ${command}
        ;;
    x-rm)
        getThirdpMetadata && \
        setValuesXrayConfig && \
        generateComposeFile && \
        runDockerCommand rm
        ;;
    version)
        if [ -f $INSTALLED_VERSION_FILE ]; then
            echo "Xray version: ${INSTALLED_VERSION}"
        else
            echo "Xray is not installed"
        fi
        ;;
    x-compose)
            xComposeCmd="docker-compose -p ${COMPOSE_PROJECT_NAME} ${ALL_ARGS}"
            echo "Advanced user: Going to execute '${xComposeCmd}'"
            ${xComposeCmd}
        ;;
    info)
           echo "Xray info:"
           echo "server port: ${XRAY_SERVER_PORT}"
           echo "project name: ${COMPOSE_PROJECT_NAME}"
           echo "Xray docker repo: ${XRAY_DOCKER_REPO}"
           echo "Xray DB docker repo: ${XRAYDB_DOCKER_REPO}"
           echo "docker mount folder: ${XRAY_MOUNT_ROOT}"
        ;;
    *)
        usage
        ;;
esac
