#!/bin/bash

env_save() {
    # save to startup_environment.sh the current environment
    # this is intended to be the first function run by 
    # - gWMS-CMSRunAnalysis.sh: when running a job on the global pool
    # - crab preparelocal, crab submit --dryrun: when running a job locally

    export DMDEBUGVAR=dmdebugvalue-env-cmsrunanalysis
    export JOBSTARTDIR=$PWD
    export HOME=${HOME:-$PWD}

    ## FIXME TODO
    # (env | grep cmsrel) || echo no cmsrel 1
    # (declare -p | grep cmsrel) || echo no cmsrel 2
    # (declare -pf | grep cmsrel) || echo no cmsrel 3

    ## FIXME TODO
    # declare -p | grep -vi "path" > startup_environment.sh

    # echo "DM DEBUG: cat startup_environment.sh"
    # basename -- "$0"
    # dirname -- "$0"
    # echo $PWD
    # ls -lrth
    # cat startup_environment.sh

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

env_cms_load() {
    ### source the CMSSW stuff using either OSG or LCG style entry env. or CVMFS
    echo "======== CMS environment load starting at $(TZ=GMT date) ========"
    CMSSET_DEFAULT_PATH=""
    if [ -f "$VO_CMS_SW_DIR"/cmsset_default.sh ]
    then  #   LCG style --
        echo "WN with a LCG style environment, thus using VO_CMS_SW_DIR=$VO_CMS_SW_DIR"
        CMSSET_DEFAULT_PATH=$VO_CMS_SW_DIR/cmsset_default.sh
    elif [ -f "$OSG_APP"/cmssoft/cms/cmsset_default.sh ]
    then  #   OSG style --
        echo "WN with an OSG style environment, thus using OSG_APP=$OSG_APP"
        CMSSET_DEFAULT_PATH=$OSG_APP/cmssoft/cms/cmsset_default.sh CMSSW_3_3_2
    elif [ -f "$CVMFS"/cms.cern.ch/cmsset_default.sh ]
    then
        echo "WN with CVMFS environment, thus using CVMFS=$CVMFS"
        CMSSET_DEFAULT_PATH=$CVMFS/cms.cern.ch/cmsset_default.sh
    elif [ -f /cvmfs/cms.cern.ch/cmsset_default.sh ]
    then  # ok, lets call it CVMFS then
        CVMFS=/cvmfs/cms.cern.ch
        echo "WN missing VO_CMS_SW_DIR/OSG_APP/CVMFS environment variable, forcing it to CVMFS=$CVMFS"
        CMSSET_DEFAULT_PATH=$CVMFS/cmsset_default.sh
    else
        echo "Error during job bootstrap: VO_CMS_SW_DIR, OSG_APP, CVMFS or /cvmfs were not found." >&2
        echo "  Because of this, we can't load CMSSW. Not good." >&2
        exit 11003
    fi
    . $CMSSET_DEFAULT_PATH
    echo "export CMSSET_DEFAULT_PATH=$CMSSET_DEFAULT_PATH" >> startup_environment.sh
    echo -e "========  CMS environment load finished at $(TZ=GMT date) ========\n"
}
