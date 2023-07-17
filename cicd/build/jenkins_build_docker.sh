#!/bin/bash

## example manual run
# export RELEASE_TAG=v3.230714
# export IMAGE_TAG=v3.230714.dmapelli
# export RPM_REPO=dmapelli
# export WORKSPACE=./
# bash jenkins_build_docker.sh

set -euo pipefail
set -x

if [ -z ${IMAGE_TAG} ]; then
  IMAGE_TAG=${RELEASE_TAG}
fi

echo "(DEBUG) variables from upstream jenkin job (CRABServer_BuildImage_20220127):"
echo "(DEBUG)   \- BRANCH: ${BRANCH}"
echo "(DEBUG)   \- RELEASE_TAG: ${RELEASE_TAG}"
echo "(DEBUG)   \- IMAGE_TAG: $IMAGE_TAG"
echo "(DEBUG) jenkin job's env variables:"
echo "(DEBUG)   \- WORKSPACE: $WORKSPACE"
echo "(DEBUG) variables for manual run:"
echo "(DEBUG)   \- RPM_REPO: $RPM_REPO"  # <empty> (defaults to crab_$BRANCH), belforte, dmapelli ...
echo "(DEBUG) end"

# RPM_REPO: if set, used to flag manual execution. otherwise run by jenkins
if [[ -z $RPM_REPO ]]; then
    # default, run with jenkins
    if [[ -z $BRANCH ]]; then echo "RPM_REPO and BRANCH are empty at the same time, exiting"; exit 1; fi
    export RPM_REPO=crab_${BRANCH};
fi

# use docker config on our WORKSPACE area, avoid replace default creds in ~/.docker that many pipeline depend on it
export DOCKER_CONFIG=$PWD/docker_login

#build and push crabtaskworker image
git clone https://github.com/dmwm/CRABServer.git
cd CRABServer/Docker

#replace where RPMs are stored
RPM_RELEASETAG_HASH=$(curl -s http://cmsrep.cern.ch/cmssw/repos/comp.$RPM_REPO/slc7_amd64_gcc630/latest/RPMS.json | grep -oP '(?<=crabtaskworker\+)(.*)(?=":)' | head -1)
sed -i.bak -e "/export REPO=*/c\export REPO=comp.$RPM_REPO" install.sh
echo "(DEBUG) diff dmwm/CRABServer/Docker/install.sh"
ls .
diff -u install.sh.bak install.sh || true
echo "(DEBUG) end"

if [[ -z RPM_REPO ]]; then
  # jenkins
  # use cmscrab robot account credentials
  docker login registry.cern.ch --username $HARBOR_CMSCRAB_USERNAME --password-stdin <<< $HARBOR_CMSCRAB_PASSWORD
else
  # manual
  docker login registry.cern.ch
fi

docker build . -t registry.cern.ch/cmscrab/crabtaskworker:${IMAGE_TAG} --network=host \
        --build-arg RELEASE_TAG=${RELEASE_TAG} \
        --build-arg RPM_RELEASETAG_HASH=${RPM_RELEASETAG_HASH}
docker push registry.cern.ch/cmscrab/crabtaskworker:${IMAGE_TAG}
docker rmi registry.cern.ch/cmscrab/crabtaskworker:${IMAGE_TAG}

#build and push crabserver image
cd $WORKSPACE
git clone https://github.com/dmwm/CMSKubernetes.git
cd CMSKubernetes/docker/

#get HG version tag from comp.crab_${BRANCH} repo, e.g. HG2201a-cde79778caecdc06e9b316b5530c1da5
HGVERSION=$(curl -s "http://cmsrep.cern.ch/cmssw/repos/comp.$RPM_REPO/slc7_amd64_gcc630/latest/RPMS.json" | grep -oP 'HG\d{4}(.*)(?=":)' | head -1)
sed -i.bak -e "/REPO=\"comp*/c\REPO=\"comp.$RPM_REPO\"" -e "s/VER=HG.*/VER=$HGVERSION/g" -- crabserver/install.sh
echo "(DEBUG) diff dmwm/CMSKubernetes/docker/crabserver/install.sh"
diff -u crabserver/install.sh.bak crabserver/install.sh || true
echo "(DEBUG) end"

if [[ -z RPM_REPO ]]; then
  # jenkins
  # relogin to using cmsweb robot account
  docker login registry.cern.ch --username $HARBOR_CMSWEB_USERNAME --password-stdin <<< $HARBOR_CMSWEB_PASSWORD
else
  # manual
  docker login registry.cern.ch
fi
CMSK8STAG=${IMAGE_TAG} ./build.sh "crabserver"
