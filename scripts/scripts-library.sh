#!/usr/bin/env bash

# Copyright 2014, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


## Vars ----------------------------------------------------------------------
LINE='----------------------------------------------------------------------'
MAX_RETRIES=${MAX_RETRIES:-5}
ANSIBLE_PARAMETERS=${ANSIBLE_PARAMETERS:-""}
STARTTIME="${STARTTIME:-$(date +%s)}"
COMMAND_LOGS=${COMMAND_LOGS:-"/openstack/log/ansible_cmd_logs"}

ZUUL_PROJECT="${ZUUL_PROJECT:-}"
GATE_EXIT_LOG_COPY="${GATE_EXIT_LOG_COPY:-false}"
GATE_EXIT_LOG_GZIP="${GATE_EXIT_LOG_GZIP:-true}"
GATE_EXIT_RUN_ARA="${GATE_EXIT_RUN_ARA:-true}"
GATE_EXIT_RUN_DSTAT="${GATE_EXIT_RUN_DSTAT:-true}"
# If this is a gate node from OpenStack-Infra Store all logs into the
#  execution directory after gate run.
if [[ -n "$ZUUL_PROJECT" ]]; then
  GATE_EXIT_LOG_COPY=true
fi


# The default SSHD configuration has MaxSessions = 10. If a deployer changes
#  their SSHD config, then the ANSIBLE_FORKS may be set to a higher number. We
#  set the value to 10 or the number of CPU's, whichever is less. This is to
#  balance between performance gains from the higher number, and CPU
#  consumption. If ANSIBLE_FORKS is already set to a value, then we leave it
#  alone.
#  ref: https://bugs.launchpad.net/openstack-ansible/+bug/1479812
if [ -z "${ANSIBLE_FORKS:-}" ]; then
  CPU_NUM=$(grep -c ^processor /proc/cpuinfo)
  if [ ${CPU_NUM} -lt "10" ]; then
    ANSIBLE_FORKS=${CPU_NUM}
  else
    ANSIBLE_FORKS=10
  fi
fi


## Functions -----------------------------------------------------------------
# Determine the distribution we are running on, so that we can configure it
# appropriately.
function determine_distro {
    source /etc/os-release 2>/dev/null
    export DISTRO_ID="${ID}"
    export DISTRO_NAME="${NAME}"
    export DISTRO_VERSION_ID="${VERSION_ID}"
}

function ssh_key_create {
  # Ensure that the ssh key exists and is an authorized_key
  key_path="${HOME}/.ssh"
  key_file="${key_path}/id_rsa"

  # Ensure that the .ssh directory exists and has the right mode
  if [ ! -d ${key_path} ]; then
    mkdir -p ${key_path}
    chmod 700 ${key_path}
  fi

  # Ensure a full keypair exists
  if [ ! -f "${key_file}" -o ! -f "${key_file}.pub" ]; then

    # Regenrate public key if private key exists
    if [ -f "${key_file}" ]; then
      ssh-keygen -f ${key_file} -y > ${key_file}.pub
    fi

    # Delete public key if private key missing
    if [ ! -f "${key_file}" ]; then
      rm -f ${key_file}.pub
    fi

    # Regenerate keypair if both keys missing
    if [ ! -f "${key_file}" -a ! -f "${key_file}.pub" ]; then
      ssh-keygen -t rsa -f ${key_file} -N ''
    fi

  fi

  # Ensure that the public key is included in the authorized_keys
  # for the default root directory and the current home directory
  key_content=$(cat "${key_file}.pub")
  if ! grep -q "${key_content}" ${key_path}/authorized_keys; then
    echo "${key_content}" | tee -a ${key_path}/authorized_keys
  fi
}

function exit_state {
  set +x
  TOTALSECONDS="$(( $(date +%s) - STARTTIME ))"
  info_block "Run Time = ${TOTALSECONDS} seconds || $((TOTALSECONDS / 60)) minutes"
  if [ "${1}" == 0 ];then
    info_block "Status: Success"
  else
    info_block "Status: Failure"
  fi
  exit ${1}
}

function exit_success {
  set +x
  exit_state 0
}

function exit_fail {
  set +x
  log_instance_info
  info_block "Error Info - $@"
  exit_state 1
}

function find_log_files {
  find "${GATE_LOG_DIR}/" -type f \
    ! -name "*.gz" \
    ! -name '*.html' \
    ! -name '*.subunit' \
    ! -name 'ansible.sqlite'
}

function rename_log_files {
  find_files |\
    while read filename; do \
      mv ${filename} ${filename}.txt || echo "WARNING: Could not rename ${filename}"; \
    done
}

function compress_log_files {
  # We use 'command' to ensure that we're not executing with an alias.
  GZIP_CMD="command gzip --force --best"
  find_files |\
    while read filename; do \
      ${GZIP_CMD} ${filename} || echo "WARNING: Could not gzip ${filename}"; \
    done
}

function gate_job_exit_tasks {
  # This environment variable captures the exit code
  # which was present when the trap was initiated.
  # This would be the success/failure of the test.
  TEST_EXIT_CODE=${TEST_EXIT_CODE:-$?}

  # Specify a default location to capture logs into,
  # just in case one is not provided (eg: when not run
  # by zuul).
  GATE_LOG_DIR=${GATE_LOG_DIR:-/opt/openstack-ansible/logs}

  # If this is a gate node from OpenStack-Infra Store all logs into the
  #  execution directory after gate run.
  if [ "$GATE_EXIT_LOG_COPY" == true ]; then
    if [ "$GATE_EXIT_RUN_DSTAT" == true ]; then
      generate_dstat_charts || true
    fi

    mkdir -p "${GATE_LOG_DIR}/host" "${GATE_LOG_DIR}/openstack"
    RSYNC_OPTS="--archive --safe-links --ignore-errors --quiet --no-perms --no-owner --no-group"
    rsync $RSYNC_OPTS /var/log/ "${GATE_LOG_DIR}/host" || true
    rsync $RSYNC_OPTS /openstack/log/ "${GATE_LOG_DIR}/openstack" || true
    # Rename all files gathered to have a .txt suffix so that the compressed
    # files are viewable via a web browser in OpenStack-CI.
    rename_log_files

    # Generate the ARA report if enabled
    if [ "$GATE_EXIT_RUN_ARA" == true ]; then

      # Define the ARA path for reusability
      ARA_CMD="/opt/ansible-runtime/bin/ara"

      # Create the ARA log directory and store the sqlite source database
      mkdir ${GATE_LOG_DIR}/ara-report
      rsync $RSYNC_OPTS "${HOME}/.ara/ansible.sqlite" "${GATE_LOG_DIR}/ara-report/"

      # Generate the ARA subunit report so that the
      # results reflect in OpenStack-Health
      mkdir "${GATE_LOG_DIR}/ara-data"
      ${ARA_CMD} generate subunit "${GATE_LOG_DIR}/ara-data/testrepository.subunit" || true
    fi
    # Compress the files gathered so that they do not take up too much space.
    if [ "$GATE_EXIT_LOG_GZIP" == true ]; then
      compress_files
    fi
    # Ensure that the files are readable by all users, including the non-root
    # OpenStack-CI jenkins user.
    chmod -R ugo+rX "${GATE_LOG_DIR}"
    chown -R $(whoami) "${GATE_LOG_DIR}"
  fi
}

function run_dstat {
  if [ "$GATE_EXIT_RUN_DSTAT" == true ]; then
    case ${DISTRO_ID} in
      centos|rhel)
          # Prefer dnf over yum for CentOS.
          which dnf &>/dev/null && RHT_PKG_MGR='dnf' || RHT_PKG_MGR='yum'
          $RHT_PKG_MGR -y install dstat
          ;;
      ubuntu)
          apt-get update
          DEBIAN_FRONTEND=noninteractive apt-get -y install dstat
          ;;
      opensuse)
          zypper -n install -l dstat
          ;;
    esac

    # https://stackoverflow.com/a/20338327 executing in ()& decouples the dstat
    # process from scripts-library to prevent hung builds if dstat fails to exit
    # for any reason.
    (dstat -tcmsdn --top-cpu --top-mem --top-bio --nocolor --output /openstack/log/instance-info/dstat.csv 3 > /openstack/log/instance-info/dstat.log)&
  fi
}

function generate_dstat_charts {
  kill $(pgrep -f dstat)
  if [[ ! -d /opt/dstat_graph ]]; then
    git clone https://github.com/Dabz/dstat_graph /opt/dstat_graph
  fi
  pushd /opt/dstat_graph
    /usr/bin/env bash -e ./generate_page.sh /openstack/log/instance-info/dstat.csv >> /openstack/log/instance-info/dstat.html
  popd
}

function print_info {
  PROC_NAME="- [ $@ ] -"
  printf "\n%s%s\n" "$PROC_NAME" "${LINE:${#PROC_NAME}}"
}

function info_block {
  echo "${LINE}"
  print_info "$@"
  echo "${LINE}"
}

function log_instance_info {
  set +x
  # Get host information post initial setup and reset verbosity
  if [ ! -d "/openstack/log/instance-info" ];then
    mkdir -p "/openstack/log/instance-info"
  fi
  get_instance_info
  set -x
}

function get_repos_info {
  for i in /etc/apt/sources.list /etc/apt/sources.list.d/* /etc/yum.conf /etc/yum.repos.d/* /etc/zypp/repos.d/*; do
    if [ -f "${i}" ]; then
      echo -e "\n$i"
      cat $i
    fi
  done
}

# Get instance info
function get_instance_info {
  TS="$(date +"%H-%M-%S")"
  (cat /etc/resolv.conf && \
    which systemd-resolve &> /dev/null && \
      systemd-resolve --statistics && \
        cat /etc/systemd/resolved.conf) > \
          "/openstack/log/instance-info/host_dns_info_${TS}.log" || true
  { tracepath "8.8.8.8" -m 5 2>/dev/null || tracepath "8.8.8.8"; } > \
    "/openstack/log/instance-info/host_tracepath_info_${TS}.log" || true
  { tracepath6 "2001:4860:4860::8888" -m 5 2>/dev/null || tracepath6 "2001:4860:4860::8888"; } >> \
    "/openstack/log/instance-info/host_tracepath_info_${TS}.log" || true
  if [ "$(which lxc-ls)" ]; then
    lxc-ls --fancy > \
      "/openstack/log/instance-info/host_lxc_container_info_${TS}.log" || true
  fi
  if [ "$(which lxc-checkconfig)" ]; then
    lxc-checkconfig > \
      "/openstack/log/instance-info/host_lxc_config_info_${TS}.log" || true
  fi
  (iptables -vnL && iptables -t nat -vnL && iptables -t mangle -vnL) > \
    "/openstack/log/instance-info/host_firewall_info_${TS}.log" || true
  if [ "$(which ansible)" ]; then
    ANSIBLE_HOST_KEY_CHECKING=False \
      ansible -i "localhost," localhost -m setup > \
        "/openstack/log/instance-info/host_system_info_${TS}.log" || true
  fi
  get_repos_info > \
    "/openstack/log/instance-info/host_repo_info_${TS}.log" || true

  determine_distro
  case ${DISTRO_ID} in
      centos|rhel|fedora|opensuse)
          rpm -qa > \
            "/openstack/log/instance-info/host_packages_info_${TS}.log" || true
          ;;
      ubuntu|debian)
          dpkg-query --list > \
            "/openstack/log/instance-info/host_packages_info_${TS}.log" || true
          ;;
  esac
}

function get_pip {

  # The python executable to use when executing get-pip is passed
  # as a parameter to this function.
  GETPIP_PYTHON_EXEC_PATH="${1:-$(which python)}"

  # Download the get-pip script using the primary or secondary URL
  GETPIP_CMD="curl --silent --show-error --retry 5"
  GETPIP_FILE="/opt/get-pip.py"
  # If GET_PIP_URL is set, then just use it
  if [ -n "${GET_PIP_URL:-}" ]; then
    ${GETPIP_CMD} ${GET_PIP_URL} > ${GETPIP_FILE}
  else
    # Otherwise, try the two standard URL's
    ${GETPIP_CMD} https://bootstrap.pypa.io/get-pip.py > ${GETPIP_FILE}\
      || ${GETPIP_CMD} https://raw.githubusercontent.com/pypa/get-pip/master/get-pip.py > ${GETPIP_FILE}
  fi

  ${GETPIP_PYTHON_EXEC_PATH} ${GETPIP_FILE} \
    pip setuptools wheel \
    --constraint global-requirement-pins.txt \
    || ${GETPIP_PYTHON_EXEC_PATH} ${GETPIP_FILE} \
         pip setuptools wheel \
         --constraint global-requirement-pins.txt \
         --isolated
}

function get_bowling_ball_tests {
  # Retrieve the latest bowling ball test script in case we don't already have it.
  if [ -f scripts/rolling_tests.py ]; then
      return
  fi

  curl --silent https://raw.githubusercontent.com/openstack/openstack-ansible-ops/master/bowling_ball/rolling_tests.py > scripts/rolling_tests.py
}

function start_bowling_ball_tests {
  # The tests will pull Keystone information from the env vars defined in openrc
  source ~/openrc
  # Get the list of services to test for from the script, so we're not hard coding.
  for SERVICE in $(python ./scripts/rolling_tests.py list | cut -d - -f 1); do
   # Start the scripts in the background and wait between each invocation.
   # Without the wait, they do not all launch.
   python ./scripts/rolling_tests.py $SERVICE &
   sleep 1
   echo "Started $SERVICE test in background"
  done
}

function kill_bowling_ball_tests {
  pkill -f rolling_tests
}

function print_bowling_ball_results {
  grep "failure rate" /var/log/*_rolling.log
}

## Signal traps --------------------------------------------------------------
# Trap all Death Signals and Errors
trap "exit_fail ${LINENO} $? 'Received STOP Signal'" SIGHUP SIGINT SIGTERM
trap "exit_fail ${LINENO} $?" ERR

## Pre-flight check ----------------------------------------------------------
# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
  info_block "This script must be run as root"
  exit_state 1
fi

# Check that we are in the root path of the cloned repo
if [ ! -d "etc" -a ! -d "scripts" -a ! -d "playbooks" ]; then
  info_block "** ERROR **"
  echo "Please execute this script from the root directory of the cloned source code."
  echo -e "Example: /opt/openstack-ansible/\n"
  exit_state 1
fi


## Exports -------------------------------------------------------------------
# Export known paths
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# Export the home directory just in case it's not set
export HOME="/root"

if [[ -f "/usr/local/bin/openstack-ansible.rc" ]];then
  source "/usr/local/bin/openstack-ansible.rc"
fi
