#!/bin/bash

## @file
## @author Martin Kjellstrand <martin.kjellstrand@madworx.se>
## @par URL
## https://github.com/madworx/cd-ci-glue @n
##
## @defgroup TravisCI Travis CI
## @defgroup GitHub GitHub.org
## @defgroup AWS Amazon Web Services
## @defgroup Artifactory JFrog Artifactory
## @defgroup DockerHub Docker Hub


# Private functions - do not invoke directly!

_artifactory_ensure_cli() {
    : "${_JFROG_INSTALL_URL:=https://getcli.jfrog.io}"
    if ! type -p jfrog ; then
        if ! type -p ./jfrog ; then
            ## TODO: Test cases with incorrect download URL
            ## TODO: Check if download/install worked.
            ## TODO: Validate that we can run the binary.
            curl -sfL "${_JFROG_INSTALL_URL}" | sh > /dev/null 2>&1 || exit 1
            if [ -x ./jfrog ] ; then
                echo "./jfrog"
            else
                echo "FATAL: Failed to download/produce jfrog CLI. Aborting." 1>&2
                exit 1
            fi
        fi
    fi
}


_artifactory_ensure_environment() {
    if [[ -v ARTIFACTORY_URL ]] && [[ -v ARTIFACTORY_USER ]] && [[ -v ARTIFACTORY_PASSWORD ]] ; then
        _artifactory_ensure_cli
    else
        echo "FATAL: Artifactory environment variables \$ARTIFACTORY_URL, \$ARTIFACTORY_USER" 1>&2
        echo "or \$ARTIFACTORY_PASSWORD not set. Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi
}


_aws_ensure_environment() {
    if [[ -v AWS_ACCESS_KEY_ID ]] && [[ -v AWS_SECRET_ACCESS_KEY ]] && [[ -v AWS_DEFAULT_REGION ]] ; then
        # validate tool(s) exist.
        if ! type -p aws >/dev/null 2>&1 ; then
            echo "FATAL: 'aws' command not found. Please install 'awscli' package." 1>&2
            exit 1
        fi
        _docker_ensure_cli
    else
        echo "FATAL: awscli environment variables \$AWS_ACCESS_KEY_ID, \$AWS_SECRET_ACCESS_KEY" 1>&2
        echo "or \$AWS_DEFAULT_REGION not set. Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi
}


_docker_ensure_cli() {
    if ! type -p docker >/dev/null 2>&1 ; then
        echo "FATAL: 'docker' command not found. Please install docker engine/cli." 1>&2
        exit 1
    fi
}


_dockerhub_ensure_environment() {
    if [[ -v DOCKER_USERNAME ]] && [[ -v DOCKER_PASSWORD ]] ; then
        _docker_ensure_cli
    else
        echo "FATAL: Docker Hub username/password environment variables " 1>&2
        echo "       DOCKER_USERNAME and/or DOCKER_PASSWORD not set. Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi
}


#
# Argument: $1 = repository name; e.g. `madworx/docshell`.
# Argument: $2 = branch name (optional)
#
_github_doc_prepare() {    
    if [[ ! -v GH_TOKEN ]] ; then
        echo "FATAL: GitHub token environment variable GH_TOKEN not set." 1>&2
        echo "       Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi
    
    if [[ -z "$1" ]] ; then
        echo "FATAL: Argument 1 (repository name, e.g. madworx/docshell) not set." 1>&2
        echo "       Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi

    REPO="https://${GH_TOKEN}@github.com/$1"
    
    TMPDR="$(mktemp -d)"
    git clone -q "${REPO}" "${TMPDR}" || exit 1
    pushd "${TMPDR}" >/dev/null || exit 1
    git config --local user.email "support@travis-ci.org"
    git config --local user.name  "Travis CI"
    if [ -n "$2" ] ; then
        git checkout "$2" >/dev/null 2>&1 || exit 1
    fi
    popd >/dev/null || exit 1
    echo "${TMPDR}"
}


##
## @fn artifactory_setup()
##
## @brief (Possibly download) and configure the `jfrog` CLI utility.
##
## @par Environment variables
##  @b ARTIFACTORY_URL Specifies the URL to your JFrog Artifactory installation. @n
##  @b ARTIFACTORY_NAME Specifies the username to connect using. @n
##  @b ARTIFACTORY_PASSWORD Specifies the password/apikey to connect using. @n
##
## @par Example
## `$ artifactory_setup` @n
##
## @ingroup Artifactory
artifactory_setup() {
    JFROG_CLI=$(_artifactory_ensure_environment) || exit 1
    $JFROG_CLI rt config --interactive=false --url "${ARTIFACTORY_URL}" \
        --user "${ARTIFACTORY_USER}" --apikey "${ARTIFACTORY_PASSWORD}" || exit 1
    return
}


##
## @fn awsecr_login()
##
## @brief Login to Amazon Elastic Container Registry. (ECR)
##
## @par Environment variables
##  @b AWS_ACCESS_KEY_ID Specifies an AWS access key associated with an IAM user or role. @n
##  @b AWS_SECRET_ACCESS_KEY Specifies the secret key associated with the access key. @n
##  @b AWS_DEFAULT_REGION Specifies the AWS Region to send the request to. @n
##
## @details   Outputs   the   full   AWS   ECR   repository   URL   to
## `stdout`. (e.g. `https://<aws_account_id>.dkr.ecr.<region>.amazonaws.com`)
##
## @par Example
## `$ export REGISTRY_URL="$(awsecr_login)" || exit 1` @n
## `$ docker run "${REGISTRY_URL}/madworx/robotframework-kicadlibrary"` @n
##
## @ingroup AWS
awsecr_login() {
    _aws_ensure_environment || exit 1
    LOGIN_STR=$(aws ecr get-login) || exit 1
    LOGIN_SH=${LOGIN_STR/-e none /}
    REGISTRY_PATH=${LOGIN_SH/* /}
    REGISTRY_PATH=${REGISTRY_PATH/https*:\/\//}

    sh - <<<"${LOGIN_SH}" >/dev/null 2>&1 || exit 1
    echo "${REGISTRY_PATH}"
}


##
## @fn awsecr_push_image()
##
## @brief Push a locally built docker image to Amazon ECR.
##
## @param image  Image identifier to push (e.g. `madworx/docshell:3.14`).
##
## @par Environment variables
##  @b AWS_ACCESS_KEY_ID Specifies an AWS access key associated with an IAM user or role. @n
##  @b AWS_SECRET_ACCESS_KEY Specifies the secret key associated with the access key. @n
##  @b AWS_DEFAULT_REGION Specifies the AWS Region to send the request to. @n
##
## @details This  function will as  a side-effect tag the  local image
## with the ECR  remote registry URL prefix. Will  output the complete
## path to the pushed image onto `stdout`
## (e.g. 863710587213.dkr.ecr.eu-north-1.amazonaws.com/madworx/docker-netbsd:8.0).
##
## @par (You do not need to call `awsecr_login()` before calling this function.)
##
## @par Example
## `$ docker build -t madworx/sample:1.0.1 .` @n
## `$ FULL_PATH="$(awsecr_push_image madworx/sample:1.0.1)" || exit 1` @n
## `$ docker run "${FULL_PATH}"`
##
## @ingroup AWS
awsecr_push_image() {
    _aws_ensure_environment || exit 1
    REGISTRY_URL=$(awsecr_login) || exit 1
    FULL_PATH="${REGISTRY_URL}/${1}"
    docker tag "${1}" "${FULL_PATH}" || exit 1
    docker push "${FULL_PATH}" > /dev/null || exit 1
    echo "${FULL_PATH}"
}


##
## @fn dockerhub_push_image()
##
## @brief Push image to Docker Hub
##
## @param image  Image identifier to push (e.g. `madworx/debian-archive:lenny`).
##
## @par Environment variables
##  @b DOCKER_USERNAME Valid username for Docker Hub. @n
##  @b DOCKER_PASSWORD Valid password for Docker Hub. @n
##
## @details Pushes a docker image from the local machine to the Docker
## Hub  repository,  logging  in   using  the  `$DOCKER_USERNAME`  and
## `$DOCKER_PASSWORD` environment  variables. You need to  have tagged
## this image beforehand. (i.e. `docker tag`)
##
## @par Example
## `$ docker build -t madworx/debian-archive:lenny-04815d2 .` @n
## <em>...perform testing of built docker image....</em> @n
## `$ docker tag madworx/debian-archive:lenny-04815d2 madworx/debian-archive:lenny` @n
## `$ dockerhub_push_image madworx/debian-archive:lenny` @n
##
## @ingroup DockerHub
dockerhub_push_image() {
    _dockerhub_ensure_environment || exit 1
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin && \
        docker push "$1"
}


##
## @fn dockerhub_set_description()
##
## @brief Set the image description on Docker Hub.
##
## @param repository  Repository name; e.g. `madworx/docshell`.
## @param filename    Filename/path containing description; e.g. `README.md`.
##
## @par Environment variables
##  @b DOCKER_USERNAME Valid username for Docker Hub. @n
##  @b DOCKER_PASSWORD Valid password for Docker Hub. @n
##
## @par Example
## `$ git clone https://github.com/madworx/docshell` @n
## `$ cd docshell` @n
## `$ dockerhub_set_description madworx/docshell README.md` @n
##
## @ingroup DockerHub
dockerhub_set_description() {
    _dockerhub_ensure_environment || exit 1
    : "${_DOCKERHUB_URL:=https://hub.docker.com/v2}"
    echo "Setting Docker Hub description..."
    if [ -z "$1" ] ; then
        echo "FATAL: Missing argument 1 (repository name. e.g. madworx/docshell)" 1>&2
        echo "" 1>&2
        exit 1
    fi

    if [ -z "$2" ] || [ ! -r "$2" ] || [ -d "$2" ] ; then
        echo "FATAL: Argument 2 (file name containing description) missing, " 1>&2
        echo "       or doesn't point to a readable entity. Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi

    echo "Logging onto Docker Hub..."
    PAYLOAD='{"username": "'"${DOCKER_USERNAME}"'", "password": "'"${DOCKER_PASSWORD}"'"}'
    TOKEN=$(curl -f -s -H "Content-Type: application/json" -X POST -d "${PAYLOAD}" "${_DOCKERHUB_URL}/users/login/" | jq -r '.token')

    if [ -z "${TOKEN}" ] ; then
        echo "FATAL: Unable to logon to Docker Hub using provided credentials" 1>&2
        echo "       DOCKER_USERNAME and/or DOCKER_PASSWORD incorrectly set. Aborting." 1>&2
        exit 1
    fi

    echo "Setting Docker Hub description of image $1 ...."
    # shellcheck disable=SC1117
    perl -ne "BEGIN{ print '{\"full_description\":\"';} END{ print '\"}' } s#\n#\\\n#msg;s#\"#\\\\\"#msg;print;" "$2" | \
        curl -f \
             -s \
             -H "Content-Type: application/json" \
             -H "Authorization: JWT ${TOKEN}" \
             -X PATCH \
             -d@/dev/stdin \
             "${_DOCKERHUB_URL}/repositories/$1/" >/dev/null
}


##
## @fn github_pages_prepare()
##
## @brief Prepare a local directory for working with GitHub pages
##
## @param repository  GitHub repository; e.g. `madworx/docshell`.
##
## @par Environment variables
##  @b GH_TOKEN Valid GitHub personal access token. @n
##
## @details Checks out  the given repository's `gh-pages`  branch in a
## temporary directory. Outputs the temporary directory on `stdout`.
##
## @ingroup GitHub
github_pages_prepare() {
    _github_doc_prepare "${1}" "gh-pages" || exit 1
}


##
## @fn github_doc_commit()
##
## @brief Commit previously prepared documentation
##
## @param dir  Temporary directory returned from previous invocation of
##              `github_(pages|wiki)_prepare()`.
##
## @par Environment variables
##  @b GH_TOKEN Valid GitHub personal access token. @n
##
## @ingroup GitHub
github_doc_commit() {
    if [[ -z "$1" ]] ; then
        echo "FATAL: Argument 1 (temporary directory) not set." 1>&2
        echo "       Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi
    cd "$1" || exit 1
    git add -A . || exit 1
    git commit -m 'Automated documentation update' -a || return 0
    git push
}


##
## @fn github_releases_get_latest()
##
## @brief Returns the latest tagged version on the given repository.
##
## @param repository  GitHub repository; e.g. `madworx/docker-minix`.
##
## @par Environment variables
##  @b GH_TOKEN Only required if querying a private repository. @n
##
## @details @par @b Please note: @n
## There  is  a discrepancy  between  the  GitHub "Releases  API"  vs.
## what's  displayed on  the GitHub  web page.  Releases displayed  as
## "releases" on  the GitHub web  page is not  necessarily "releases",
## but actually tags.   Therefore, we instead look at  the actual tags
## since this maps better to expected UX.
##
## @ingroup GitHub
github_releases_get_latest() {
    JSON=$(curl -fs "https://${GH_TOKEN:+$GH_TOKEN@}api.github.com/repos/$1/tags") || exit 1
    LATEST_TAG="$(jq -r '.[0].name' <<<"${JSON}")" || exit 1
    # shellcheck disable=SC2001
    LATEST_TAG="$(echo "${LATEST_TAG}" | sed 's#[^a-zA-Z0-9.,_+-]##g')"
    echo "${LATEST_TAG}"
}


##
## @fn github_wiki_commit()
##
## @brief Commit previously prepared wiki directory.
##
## @deprecated  This   function  is   deprecated.   Use   the  generic
## `github_doc_commit()` function instead.
##
## @param dir  Temporary directory  returned  from  previous call  to
##            `github_(pages|wiki)_prepare()`.
##
## @par Environment variables
##  @b GH_TOKEN Valid GitHub personal access token. @n
##
## @ingroup GitHub
github_wiki_commit() {
    github_doc_commit "$1"
}


##
## @fn github_wiki_prepare()
##
## @brief Prepare a local directory for working with GitHub Wiki repo.
##
## @param repository  GitHub repository; e.g. `madworx/docshell`.
##
## @par Environment variables
##  @b GH_TOKEN Valid GitHub personal access token. @n
##
## @details Outputs  the temporary  directory name you're  supposed to
## put the Wiki files into to `stdout`.
##
## @ingroup GitHub
github_wiki_prepare() {
    TMPDR=$(_github_doc_prepare "${1}.wiki.git") || exit 1
    pushd "${TMPDR}" >/dev/null || exit 1
    git rm -r . >/dev/null 2>&1 || true
    popd >/dev/null || exit 1
    echo "${TMPDR}"
}


##
## @fn is_travis_branch_push()
##
## @brief Check if invoked from Travis CI due to a push event on a specific branch.
##
## @param branch  Branch name to compare to
##
## @par Environment variables
##  @b TRAVIS_EVENT_TYPE Variable set  by Travis CI during build-time,
##  indicating event type. @n
##  @b  TRAVIS_BRANCH Variable  set  by Travis  CI during  build-time,
##  indicating which branch we're on. @n
##
## @details Return a zero status code if this is refering to a push on
## the branch given  as argument.  If any of  the required environment
## variables  are missing,  will  emit error  message  on stderr,  but
## containue anyway  and assume that this  is not a push  event on the
## desired  branch. Please  note  that this  might  break your  script
## execution  if  running with  `-o  pipefail`  and/or `set  -eE`.   A
## work-around  for  that  fact  is described  below  in  the  example
## section.
##
## @par Example
## `# Below will fail on -opipefail, -eE etc.` @n
## `$ is_travis_branch_push devel && dockerhub_push_image madworx/qemu:dev` @n
##
## `# Below is a work-around for above behaviour.` @n
## `$ ! is_travis_branch_push devel && true || dockerhub_push_image madworx/qemu:dev` @n
##
## @ingroup TravisCI
is_travis_branch_push() {   
    if [[ ! -v TRAVIS_EVENT_TYPE ]] ; then
        echo "WARNING: Travis CI environment variable TRAVIS_EVENT_TYPE not set."    1>&2
        echo "         Unable to identify if this commit is related to PR or merge." 1>&2
        echo "" 1>&2
    fi
    if [[ ! -v TRAVIS_BRANCH ]] ; then
        echo "WARNING: Travis CI environment variable TRAVIS_BRANCH not set."          1>&2
        echo "         We'll assume this isn't related to a push on the \`$1' branch." 1>&2
        echo "" 1>&2
    fi
    [[ "${TRAVIS_EVENT_TYPE}" == "push" ]] && [[ "${TRAVIS_BRANCH}" == "$1" ]]
}


##
## @fn is_travis_master_push()
##
## @brief Check  if invoked  from Travis  CI due  to push  on `master`
## branch.
##
## @par Environment variables
##  @b TRAVIS_EVENT_TYPE Variable set  by Travis CI during build-time,
##  indicating event type. @n
##  @b  TRAVIS_BRANCH Variable  set  by Travis  CI during  build-time,
##  indicating which branch we're on. @n
##
## @details Return a  zero status code if this is  referring to a push
## to the `master` branch.
##
## @par Example
## `# Below will fail on -opipefail, -eE etc.` @n
## `$ is_travis_master_push && dockerhub_push_image madworx/qemu` @n
##
## `# Below is a work-around for above behaviour.` @n
## `$ ! is_travis_master_push && true || dockerhub_push_image madworx/qemu` @n
##
## @ingroup TravisCI
is_travis_master_push() {
    is_travis_branch_push master
}


##
## @fn is_travis_cron()
##
## @brief Check  if invoked  from Travis  CI due  to a cron event.
##
## @par Environment variables
##  @b TRAVIS_EVENT_TYPE Variable set  by Travis CI during build-time,
##  indicating event type. @n
##
## @details Return  a zero status code  if this is triggerd  by Travis
## cron.
##
## @ingroup TravisCI
is_travis_cron() {
    if [[ ! -v TRAVIS_EVENT_TYPE ]] ; then
        echo "WARNING: Travis CI environment variable TRAVIS_EVENT_TYPE not set."    1>&2
        echo "         Unable to identify if this commit is related to PR or merge." 1>&2
        echo "" 1>&2
    fi
    [[ "${TRAVIS_EVENT_TYPE}" == "cron" ]]
}