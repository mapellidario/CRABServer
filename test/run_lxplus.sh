#!/bin/bash

# run CRAB integration tests on lxplu
# laptop$ rsync -rv test/run_lxplus.sh lxplus:/afs/cern.ch/user/d/dmapelli/crab/test/202305-crabtest
# lxplus$ rm -rf ./*
# lxplus$ bash ./run_lxplus.sh

set -x
set -e

#00. set parameters

CRABClient_version=dev
CRABServer_tag=HEAD
REST_Instance=preprod
CMSSW_release=CMSSW_13_0_2
Client_Validation_Suite=No
Client_Configuration_Validation=No
Task_Submission_Status_Tracking=true
Check_Publication_Status=No
Repo_GH_Issue=mapellidario/CRABServer
Repo_Testing_Scripts=mapellidario/CRABServer
Branch_Testing_Scripts=20230509_jenkins
Test_Docker_Image=registry.cern.ch/cmscrab/crabtesting:220701
export Test_WorkDir=/tmp/dmapelli/202305-crabtest

# only when running on lxplus
export WORKSPACE=/tmp/dmapelli/$(date +%s)-crabtest

mkdir $Test_WorkDir
mkdir $WORKSPACE
cd $WORKSPACE
touch $WORKSPACE/parameters

#01. check parameters
echo "(DEBUG) client:"
echo "(DEBUG)   \- CRABClient_version: ${CRABClient_version}"
echo "(DEBUG)   \- CRABServer_tag: ${CRABServer_tag}"
echo "(DEBUG) REST:"
echo "(DEBUG)   \- REST_Instance: ${REST_Instance}"
echo "(DEBUG) CMSSW:"
echo "(DEBUG)   \- CMSSW_release: ${CMSSW_release}"
echo "(DEBUG) test parameters:"
echo "(DEBUG)   \- Client_Validation_Suite: ${Client_Validation_Suite}"
echo "(DEBUG)   \- Client_Configuration_Validation: ${Client_Configuration_Validation}"
echo "(DEBUG)   \- Task_Submission_Status_Tracking: ${Task_Submission_Status_Tracking}"
echo "(DEBUG)   \- Check_Publication_Status: ${Check_Publication_Status}"
echo "(DEBUG)   \- Repo_GH_Issue: ${Repo_GH_Issue}"
echo "(DEBUG)   \- Repo_Testing_Scripts: ${Repo_Testing_Scripts}"
echo "(DEBUG)   \- Branch_Testing_Scripts: ${Branch_Testing_Scripts}"
echo "(DEBUG)   \- Test_Docker_Image: ${Test_Docker_Image}"
echo "(DEBUG)   \- Test_WorkDir: ${Test_WorkDir}"
echo "(DEBUG) end"

#02. Prepare environment
rm -rf ${Test_WorkDir}
# docker system prune -af
mkdir artifacts
touch message_taskSubmitted 
ls -l /cvmfs/cms-ib.cern.ch/latest/ 2>&1
ls -l /cvmfs/cms.cern.ch/common/ 2>&1

## no GH
# git clone https://github.com/cms-sw/cms-bot $WORKSPACE/cms-bot

voms-proxy-init -rfc -voms cms -valid 192:00
export PROXY=$(voms-proxy-info -path 2>&1)

export PYTHONPATH=/cvmfs/cms-ib.cern.ch/jenkins-env/python/shared 
export ERR=false
#be aware that when running in singularity, we use ${WORK_DIR} set below,
#while if we run in CRAB Docker container, then ${WORK_DIR} set in Dockerfile.
export WORK_DIR=`pwd`

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

#2. Create GH issue which will be used to report results
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

## no GH
# $WORKSPACE/cms-bot/create-gh-issue.py -r $Repo_GH_Issue -t "$issueTitle" -R message_configuration


#pass issueTitle to sub-jobs
echo "issueTitle=${issueTitle}" >> $WORKSPACE/parameters

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

## no GH
# $WORKSPACE/cms-bot/create-gh-issue.py -r $Repo_GH_Issue -t "$issueTitle" -R message_taskSubmitted

if $ERR ; then
	exit 1
fi
