#!/bin/bash

env_save() {
    # save to startup_environment.sh the current environment
    # this is intended to be the first function run by 
    # - gWMS-CMSRunAnalysis.sh: when running a job on the global pool
    # - crab preparelocal, crab submit --dryrun: when running a job locally

    export DMDEBUGVAR=dmdebugvalue-env-cmsrunanalysis
    export JOBSTARTDIR=$PWD
    export HOME=${HOME:-$PWD}

    declare -p | grep -vi "path" > startup_environment.sh
}

env_set_local () {
    # when running a job locally, we need to set manually some variables that 
    # are set for us when running on the global pool.

    export SCRAM_ARCH=$(scramv1 arch)
    export REQUIRED_OS=rhel7
    export CRAB_RUNTIME_TARBALL=local
    export CRAB_TASKMANAGER_TARBALL=local
    export CRAB3_RUNTIME_DEBUG=True

}

