#!/bin/bash

# run CRAB integration tests. copy rhis script, then
# lxplus$ bash -c "source ./run.sh && submit_lxplus"
# jenkins$ bash -c "source ./run.sh && submit_jenkins"

set -x
set -e

set_env_lxplus  () {
    # Call this function only if you intend to submit the test tasks from lxplus
    # and not from jenkins

    #00. set parameters
    # client
    export CRABClient_version=dev
    export CRABServer_tag=HEAD
    # rest
    export REST_Instance=preprod
    # cmssw
    export CMSSW_release=CMSSW_13_0_2
    # which tests to submit
    export Client_Validation_Suite=No
    export Client_Configuration_Validation=No
    export Task_Submission_Status_Tracking=true
    # other test suite parameters
    export Check_Publication_Status=No
    export Repo_Testing_Scripts=mapellidario/CRABServer
    export Branch_Testing_Scripts=20230509_jenkins
    export Test_Docker_Image=registry.cern.ch/cmscrab/crabtesting:220701
    export Test_WorkDir=/tmp/$(whoami)/$(date +%s)-crabtest-workdir

    ## define the following env variable only if you want to 
    ## create a GH issue where to track the execution of the submitted tasks.
    ## achtung! you will need a gihub api token
    # export Repo_GH_Issue=mapellidario/CRABServer

    # some tweaks that come for granted when executing inside jenkins, but that
    # we need to apply manually when running on lxplus
    export WORKSPACE=/tmp/$(whoami)/$(date +%s)-crabtest-workspace
    mkdir $Test_WorkDir
    mkdir $WORKSPACE
    cd $WORKSPACE
    touch $WORKSPACE/parameters

}

validate () {

    #01. check parameters
    echo "(DEBUG) client:"
    echo "(DEBUG)   \- CRABClient_version: ${CRABClient_version}"
    echo "(DEBUG)   \- CRABServer_tag: ${CRABServer_tag}"
    echo "(DEBUG) REST:"
    echo "(DEBUG)   \- REST_Instance: ${REST_Instance}"
    echo "(DEBUG) CMSSW:"
    echo "(DEBUG)   \- CMSSW_release: ${CMSSW_release}"
    echo "(DEBUG) test parameters:"
    echo "(DEBUG)   \- Client_Validation_Suite: ${Client_Validation_Suite}"                 # boolean. =true or =No
    echo "(DEBUG)   \- Client_Configuration_Validation: ${Client_Configuration_Validation}" # boolean. =true or =No
    echo "(DEBUG)   \- Task_Submission_Status_Tracking: ${Task_Submission_Status_Tracking}" # boolean. =true or =No
    echo "(DEBUG)   \- Check_Publication_Status: ${Check_Publication_Status}"
    echo "(DEBUG)   \- Repo_GH_Issue: ${Repo_GH_Issue}"
    echo "(DEBUG)   \- Repo_Testing_Scripts: ${Repo_Testing_Scripts}"
    echo "(DEBUG)   \- Branch_Testing_Scripts: ${Branch_Testing_Scripts}"
    echo "(DEBUG)   \- Test_Docker_Image: ${Test_Docker_Image}"
    echo "(DEBUG)   \- Test_WorkDir: ${Test_WorkDir}"
    echo "(DEBUG) end"

    #02. check if we can access via cvmfs some directories that we will need later
    ls -l /cvmfs/cms-ib.cern.ch/latest/ 2>&1
    ls -l /cvmfs/cms.cern.ch/common/cmssw-* 2>&1
    ls -l /cvmfs/cms-ib.cern.ch/jenkins-env/python/shared 2>&1

    # TODO: we can improve validation. we can exit here if some conditions are not met.
    # for the time being this feels good enough.
}

prepare_environment () {

    #02. Prepare environment
    rm -rf ${Test_WorkDir}
    # docker system prune -af
    mkdir $WORKSPACE/artifacts
    touch $WORKSPACE/message_taskSubmitted 

    voms-proxy-init -rfc -voms cms -valid 192:00
    export PROXY=$(voms-proxy-info -path 2>&1)
    ## dario thinks that the following env variables are not required
    # export X509_USER_CERT=/home/cmsbld/.globus/usercert.pem 
    # export X509_USER_KEY=/home/cmsbld/.globus/userkey.pem 

    export PYTHONPATH=/cvmfs/cms-ib.cern.ch/jenkins-env/python/shared 
    export ERR=false
    #be aware that when running in singularity, we use ${WORK_DIR} set below,
    #while if we run in CRAB Docker container, then ${WORK_DIR} set in Dockerfile.
    export WORK_DIR=`pwd`
}

get_cmssw_config () {

    #1.1. Get configuration from CMSSW_release
    export CMSSW_release=${CMSSW_release}
    curl -s -O https://raw.githubusercontent.com/$Repo_Testing_Scripts/$Branch_Testing_Scripts/test/testingConfigs
    CONFIG_LINE=$(grep "CMSSW_release=${CMSSW_release};" testingConfigs)
    export SCRAM_ARCH=$(echo "${CONFIG_LINE}" | tr ';' '\n' | grep SCRAM_ARCH | sed 's|SCRAM_ARCH=||')
    export inputDataset=$(echo "${CONFIG_LINE}" | tr ';' '\n' | grep inputDataset | sed 's|inputDataset=||')
    # see https://github.com/dmwm/WMCore/issues/11051 for info about SCRAM_ARCH formatting
    export singularity=$(echo ${SCRAM_ARCH} | cut -d"_" -f 1 | tail -c 2)

    #1.2. Put configuration to file that is later being passed to sub-jobs
    echo "SCRAM_ARCH=${SCRAM_ARCH}" >> $WORKSPACE/parameters
    echo "inputDataset=${inputDataset}" >> $WORKSPACE/parameters
    echo "singularity=${singularity}" >> $WORKSPACE/parameters
    echo "Repo_GH_Issue=${Repo_GH_Issue}" >> $WORKSPACE/parameters
    echo "Repo_Testing_Scripts=${Repo_Testing_Scripts}" >> $WORKSPACE/parameters
    echo "Branch_Testing_Scripts=${Branch_Testing_Scripts}" >> $WORKSPACE/parameters
    echo "Test_Docker_Image=${Test_Docker_Image}" >> $WORKSPACE/parameters
    echo "Test_WorkDir=${Test_WorkDir}" >> $WORKSPACE/parameters
}

create_gh_issue () {
    #2. Create GH issue which will be used to report results

    git clone https://github.com/cms-sw/cms-bot $WORKSPACE/cms-bot

    echo -e "**Tests started for following configuration:**\n\n" > message_configuration
    echo -e "**Configuration:**\n\n \
    - CRABClient_version: **${CRABClient_version}**\n\
    - REST_Instance: **${REST_Instance}**\n\
    - CMSSW_release: **${CMSSW_release}**\n\
    - SCRAM_ARCH: **${SCRAM_ARCH}**" >> message_configuration
    if [ "X$CRABClient_version" == "XGH" ]; then
        echo -e "- CRABServer_tag: **${CRABServer_tag}**" >> message_configuration
    fi

    echo -e "\n**Tests started:**\n" >> message_configuration
    if [ "X$Client_Validation_Suite" == "Xtrue" ]; then
        echo -e "- [ ] Client_Validation" >> message_configuration
    fi
    if [ "X$Client_Configuration_Validation" == "Xtrue" ]; then
        echo -e "- [ ] Client_Configuration_Validation" >> message_configuration
    fi
    if [ "X$Task_Submission_Status_Tracking" == "Xtrue" ]; then
        echo -e "- [ ] Task_Submission_Status_Tracking\n" >> message_configuration
    fi    

    echo -e "Started at: `(date '+%Y-%m-%d %H:%M:%S')`\nLink to the [job](${BUILD_URL}) " >> message_configuration
    issueTitle="#${BUILD_NUMBER}: Test ${CRABClient_version} CRABClient using ${REST_Instance} REST instance and ${CMSSW_release} CMSSW release"

    $WORKSPACE/cms-bot/create-gh-issue.py -r $Repo_GH_Issue -t "$issueTitle" -R message_configuration

    #pass issueTitle to sub-jobs
    echo "issueTitle=${issueTitle}" >> $WORKSPACE/parameters
}

submit_tasks () {

    #3. Submit tasks
    if [ "X${singularity}" == X6 ] || [ "X${singularity}" == X7 ] || [ "X${singularity}" == X8 ] || [ "X${singularity}" == X9 ]; then
        echo "Starting singularity ${singularity} container."
        git clone https://github.com/$Repo_Testing_Scripts 
        cd CRABServer
        if [[ $(git rev-parse --abbrev-ref HEAD) != $Branch_Testing_Scripts ]]; then
            git checkout -t origin/$Branch_Testing_Scripts
        fi
        cd test/container/testingScripts
        scramprefix=el${singularity}
        # if [ "X${singularity}" == X6 ]; then scramprefix=cc${singularity}; fi
        # if [ "X${singularity}" == X8 ]; then scramprefix=el${singularity}; fi
        /cvmfs/cms.cern.ch/common/cmssw-${scramprefix} -- ./taskSubmission.sh || export ERR=true
    # elif [ "X${singularity}" == X7 ] || [ "X${singularity}" == X8 ] ; then
    # 	echo "Starting CRAB testing container for slc${singularity}."
    # 	export DOCKER_OPT="-u $(id -u):$(id -g) -v /home:/home -v /etc/passwd:/etc/passwd -v /etc/group:/etc/group" 
    # 	export DOCKER_ENV="-e inputDataset -e ghprbPullId -e SCRAM_ARCH -e CRABServer_tag -e Client_Validation_Suite -e Task_Submission_Status_Tracking -e Client_Configuration_Validation -e X509_USER_CERT -e X509_USER_KEY -e CMSSW_release -e REST_Instance -e CRABClient_version"
    # 	export DOCKER_VOL="-v $WORKSPACE/artifacts/:/data/CRABTesting/artifacts:Z -v /cvmfs/grid.cern.ch/etc/grid-security:/etc/grid-security  -v /cvmfs/grid.cern.ch/etc/grid-security/vomses:/etc/vomses  -v /cvmfs:/cvmfs"
    # 	docker run --rm $DOCKER_OPT $DOCKER_VOL $DOCKER_ENV --net=host \
    # 	$Test_Docker_Image -c 	\
    # 	'source taskSubmission.sh' || export ERR=true
    else 
        echo "!!! I am not prepared to run for slc${singularity}."
        exit 1
    fi

    cd ${WORK_DIR}
    mv $WORKSPACE/artifacts/* $WORKSPACE/
}

upate_gh_issue() {

    #4. Update issue with submission results
    if $ERR ; then
        echo -e "Something went wrong during task submission. Find submission log [here](${BUILD_URL}console). None of the downstream jobs were triggered." >> message_taskSubmitted
    else
        declare -A tests=( ["Task_Submission_Status_Tracking"]=submitted_tasks_TS ["Client_Validation_Suite"]=submitted_tasks_CV ["Client_Configuration_Validation"]=submitted_tasks_CCV)
        for test in "${!tests[@]}";
        do
            if [ -s "${tests[$test]}" ]; then
                echo -e "Task submission for **${test}** successfully ended.\n\`\`\`\n`cat ${tests[$test]}`\n\`\`\`\n" >> message_taskSubmitted
            fi
        done
        echo -e "Finished at: `(date '+%Y-%m-%d %H:%M:%S')`\nFind submission log [here](${BUILD_URL}console)" >> message_taskSubmitted 
    fi

    sleep 20

    $WORKSPACE/cms-bot/create-gh-issue.py -r $Repo_GH_Issue -t "$issueTitle" -R message_taskSubmitted
}

finish () {
    if $ERR ; then
        exit 1
    fi
}

submit_jenkins(){
    validate
    prepare_environment
    get_cmssw_config
    create_gh_issue
    submit_tasks
    upate_gh_issue
    finish
}

submit_lxplus(){
    set_env_lxplus

    validate
    prepare_environment
    get_cmssw_config
    if [ -n "${Repo_GH_Issue+1}" ]; then
        # enter here only if the variable Repo_GH_Issue is set.
        # ref: https://stackoverflow.com/a/42655305
        # skip the creation of the GH issue when submitting from lxplus,
        # since it requires a github api token.
        # if you have one, just set the env variables $Repo_GH_Issue.
        create_gh_issue
    fi
    submit_tasks
    if [ -n "${Repo_GH_Issue+1}" ]; then
        upate_gh_issue
    fi
    finish

}
