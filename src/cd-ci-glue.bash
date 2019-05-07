#!/bin/bash

## @file
## @author Martin Kjellstrand <martin.kjellstrand@madworx.se>
## @par URL
## https://github.com/madworx/cd-ci-glue @n
##

##
## @fn is_travis_branch_push()
## @brief Check if invoked from Travis CI on specific branch.
## @param branch Branch name to compare to
## @par Environment variables
##  @b TRAVIS_EVENT_TYPE Variable set by Travis CI during build-time, indicating event type. @n
##  @b TRAVIS_BRANCH Variable set by Travis CI during build-time, indicating which branch we're on. @n
##
## @details Return a zero status code if  this is refering to a push on
## the branch  given as argument.  If any of the  required environment
## variables  are missing,  will  emit error  message  on stderr,  but
## containue anyway  and assume that this  is not a push  event on the
## desired branch.
##
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
## @par Environment variables
##  @b TRAVIS_EVENT_TYPE Variable set by Travis CI during build-time, indicating event type. @n
##  @b TRAVIS_BRANCH Variable set by Travis CI during build-time, indicating which branch we're on. @n
##
## @details Return a  zero status code if this is  referring to a push
## to the 'master' branch.
##
is_travis_master_push() {
    is_travis_branch_push master
}

##
## @fn dockerhub_push_image()
## @brief Push image to Docker Hub
## @param image Image to push. (e.g. `madworx/debian-archive:lenny`)
## @par Environment variables
##  @b DOCKER_USERNAME Valid username for Docker Hub. @n
##  @b DOCKER_PASSWORD Valid password for Docker Hub. @n
##
## @details Push a  docker image from the local machine  to the Docker
## Hub  repository,  logging  in   using  the  `$DOCKER_USERNAME`  and
## `$DOCKER_PASSWORD` environment  variables. You need to  have tagged
## this image beforehand e.g. docker tag.
##
## @par Example
## `$ docker build -t madworx/debian-archive:lenny-04815d2 .` @n
## <em>...perform testing of built docker image....</em> @n
## `$ docker tag madworx/debian-archive:lenny-04815d2 madworx/debian-archive:lenny` @n
## `$ dockerhub_push_image madworx/debian-archive:lenny` @n
##
dockerhub_push_image() {
    if [[ -v DOCKER_USERNAME ]] && [[ -v DOCKER_PASSWORD ]] ; then
        echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin && \
            docker push "$1"
    else
        echo "FATAL: Docker hub username/password environment variables " 1>&2
        echo "       DOCKER_USERNAME and/or DOCKER_PASSWORD not set. Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi
}

##
## @fn dockerhub_set_description()
## @param repository Repository name; e.g. `madworx/docshell`.
## @param filename Filename/path containing description; e.g. `README.md`.
## @par Environment variables
##  @b DOCKER_USERNAME Valid username for Docker Hub. @n
##  @b DOCKER_PASSWORD Valid password for Docker Hub. @n
##
## @par Example
## `$ git clone https://github.com/madworx/docshell` @n
## `$ cd docshell` @n
## `$ dockerhub_set_description madworx/docshell README.md` @n
##
dockerhub_set_description() {
    : "${_DOCKERHUB_URL:=https://hub.docker.com/v2}"
    echo "Setting Docker hub description..."
    if [ -z "$1" ] ; then
        echo "FATAL: Missing argument 1 (repository name. e.g. madworx/docshell)" 1>&2
        echo "" 1>&2
        exit 1
    fi

    if [ -z "$2" ] || [ ! -r "$2" ] ; then
        echo "FATAL: Argument 2 (file name containing description) missing, " 1>&2
        echo "       or doesn't point to a readable entity. Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi

    if [[ -v DOCKER_USERNAME ]] && [[ -v DOCKER_PASSWORD ]] ; then
        echo "Logging onto Docker hub..."
        PAYLOAD='{"username": "'"${DOCKER_USERNAME}"'", "password": "'"${DOCKER_PASSWORD}"'"}'
        TOKEN=$(curl -f -s -H "Content-Type: application/json" -X POST -d "${PAYLOAD}" "${_DOCKERHUB_URL}/users/login/" | jq -r '.token')

        if [ -z "${TOKEN}" ] ; then
            echo "FATAL: Unable to logon to Docker Hub using provided credentials" 1>&2
            echo "       DOCKER_USERNAME and/or DOCKER_PASSWORD incorrectly set. Aborting." 1>&2
            exit 1
        fi

        echo "Setting Docker hub description of image $1 ...."
        # shellcheck disable=SC1117
        perl -ne "BEGIN{ print '{\"full_description\":\"';} END{ print '\"}' } s#\n#\\\n#msg;s#\"#\\\\\"#msg;print;" "$2" | \
        curl -f \
             -s \
             -H "Content-Type: application/json" \
             -H "Authorization: JWT ${TOKEN}" \
             -X PATCH \
             -d@/dev/stdin \
             "${_DOCKERHUB_URL}/repositories/$1/" >/dev/null
    else
        echo "FATAL: Docker hub username/password environment variables " 1>&2
        echo "       DOCKER_USERNAME and/or DOCKER_PASSWORD not set. Aborting." 1>&2
        echo "" 1>&2
        exit 1
    fi
}

#
# Argument: $1 = repository name. e.g. madworx/docshell.
# Argument: $2 = branch name (optional)
#
_github_doc_prepare() {    
    if [[ ! -v GH_TOKEN ]] ; then
        echo "FATAL: Github token environment variable GH_TOKEN not set." 1>&2
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
    if [ ! -z "$2" ] ; then
        git checkout "$2" >/dev/null 2>&1 || exit 1
    fi
    popd >/dev/null || exit 1
    echo "${TMPDR}"
}

##
## @fn github_wiki_prepare()
## @param repository Name of GitHub repository; e.g. `madworx/docshell`.
## @par Environment variables
##  @b GH_TOKEN Valid GitHub personal access token. @n
## @details Outputs the temporary directory name you're supposed to put the Wiki
## files into.
##
github_wiki_prepare() {
    TMPDR=$(_github_doc_prepare "${1}.wiki.git") || exit 1
    pushd "${TMPDR}" >/dev/null || exit 1
    git rm -r . >/dev/null 2>&1 || true
    popd >/dev/null || exit 1
    echo "${TMPDR}"
}

##
## @fn github_pages_prepare()
## @param repository Name of GitHub repository; e.g. `madworx/docshell`.
## @par Environment variables
##  @b GH_TOKEN Valid GitHub personal access token. @n
## @details Outputs the temporary directory of the gh-pages branch.
##
github_pages_prepare() {
    _github_doc_prepare "${1}" "gh-pages" || exit 1
}

##
## @fn github_doc_commit()
## @param dir Temporary directory  returned  from  previous call  to
##            github_(pages/wiki)_prepare().
## @par Environment variables
##  @b GH_TOKEN Valid GitHub personal access token. @n
## @details Commit previously prepared documentation
##
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
## @fn github_wiki_commit()
## @deprecated This function is deprecated. Use the generic `github_doc_commit` function instead.
## @param dir Temporary directory  returned  from  previous call  to
##            github_(pages/wiki)_prepare().
## @par Environment variables
##  @b GH_TOKEN Valid GitHub personal access token. @n
##
## Commit previously prepared wiki directory.
##
github_wiki_commit() {
    github_doc_commit "$1"
}
