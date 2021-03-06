#!/bin/bash

# ====================================================
# Script for *updating* Syndesis on OCP

# Exit if any error occurs
# Fail on a single failed command in a pipeline (if supported)
set -o pipefail

# Fail on error and undefined vars (please don't use global vars, but evaluation of functions for return values)
set -eu

# Save global script args
ARGS=("$@")

# Helper functions

# Dir where this script is located
basedir() {
    # Default is current directory
    local script=${BASH_SOURCE[0]}

    # Resolve symbolic links
    if [ -L $script ]; then
        if readlink -f $script >/dev/null 2>&1; then
            script=$(readlink -f $script)
        elif readlink $script >/dev/null 2>&1; then
            script=$(readlink $script)
        elif realpath $script >/dev/null 2>&1; then
            script=$(realpath $script)
        else
            echo "ERROR: Cannot resolve symbolic link $script"
            exit 1
        fi
    fi

    local dir=$(dirname "$script")
    local full_dir=$(cd "${dir}" && pwd)
    echo ${full_dir}
}

# Checks if a flag is present in the arguments.
hasflag() {
    filters="$@"

    if [[ ! -z ${ARGS+x} ]]; then
        for var in "${ARGS[@]}"; do
            for filter in $filters; do
              if [ "$var" = "$filter" ]; then
                  echo 'true'
                  return
              fi
            done
        done
    fi
}

# Read the value of an option.
readopt() {
    filters="$@"
    if [[ ! -z ${ARGS+x} ]]; then
        next=false
        for var in "${ARGS[@]}"; do
            if $next; then
                echo $var
                break;
            fi
            for filter in $filters; do
                if [[ "$var" = ${filter}* ]]; then
                    local value="${var//${filter}=/}"
                    if [ "$value" != "$var" ]; then
                        echo $value
                        return
                    fi
                    next=true
                fi
            done
        done
    fi
}

# Getting base dir
BASEDIR=$(basedir)

# Get configuration and other scripts
pushd > /dev/null . && cd $BASEDIR
source $BASEDIR/base_functions.sh
source $BASEDIR/common_config.sh
source $BASEDIR/libs/download_functions.sh
source $BASEDIR/libs/openshift_functions.sh
popd > /dev/null

SYNDESIS_CLI=$(get_syndesis_bin)
check_error $SYNDESIS_CLI

# Download binary files
KAMEL_CLI=$(get_kamel_bin)
check_error $KAMEL_CLI

display_usage() {
  cat <<EOT
Fuse Online Update Tool for OCP

Usage: update_ocp.sh [options]

with options:

   --version                  Print target version to update to and exit.

   --camel-k                  Update also the camel-k operator

-v --verbose                  Verbose logging
EOT
}

# ============================================================

check_syndesis() {
  # Check for a syndesis resource and update only if one exists
  set +e
  oc get syndesis >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "ERROR: No CRD Syndesis installed or no permissions to read them. Please run --setup and/or --grant as cluster-admin. Please use '--help' for more information."
    return
  fi
  set -e

  local nr=$(oc get syndesis -o name | wc -l | awk '$1=$1')
  if [ $nr -ne 1 ]; then
    echo "ERROR: Exactly 1 syndesis resource expected, but $nr found"
    return
  fi
}

# ==============================================================

if [ $(hasflag --help -h) ]; then
    display_usage
    exit 0
fi

if [ $(hasflag --verbose -v) ]; then
    export PS4='+($(basename ${BASH_SOURCE[0]}):${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -x
fi

# ==================================================================

if [ $(hasflag --version) ]; then
    echo "Update to Fuse Online $TAG"
    echo
    echo "syndesis-operator:  ${SYNDESIS_VERSION}"
    echo "camel-k-operator:  ${CAMEL_K_VERSION}"
    exit 0
fi

# Check for OC
setup_oc

# Check whether there is an installation
check_error "$(check_syndesis)"


# make sure pull secret is present, only required from
create_secret_if_not_present

# Update syndesis operator
echo "Update Syndesis operator"
$SYNDESIS_CLI install operator

result=$(oc secrets link syndesis-operator syndesis-pull-secret --for=pull >$ERROR_FILE 2>&1)
check_error $result

if [ $(hasflag --camel-k) ]; then
    echo "Update Camel k operator"
    oc delete deployment camel-k-operator --ignore-not-found
    $KAMEL_CLI install --skip-cluster-setup

    result=$(oc secrets link camel-k-operator syndesis-pull-secret --for=pull >$ERROR_FILE 2>&1)
    check_error $result
fi

cat <<EOT
========================================================
Fuse Online operator has been updated to $TAG !
Please wait for the upgrade process to be finished by the operator.
EOT
