#!/bin/bash

set -x

#
# A small collection of helper  functions for interacting with Github,
# Docker Hub, and Travis CI.
#
# Primarily designed to be sourced in Travis CI scripts.
#

#
# Return a  zero status  code if  this is  refering to  a push  to the
# specified branch.
#
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


#
# Return a  zero status  code if this  is referring to  a push  to the
# 'master' branch.
#
is_travis_master_push() {
    is_travis_branch_push master
}

#
# Argument $1 = image name e.g. madworx/debian-archive:lenny
#
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

#
# Argument: $1 = repository name. e.g. madworx/docshell
# Argument: $2 = file name containing description
#
dockerhub_set_description() {
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
        TOKEN=$(curl -s -H "Content-Type: application/json" -X POST \
                     -d '{"username": "'"${DOCKER_USERNAME}"'", "password": "'"${DOCKER_PASSWORD}"'"}' \
                     'https://hub.docker.com/v2/users/login/' | jq -r '.token')

        echo "Setting Docker hub description of image $1 ...."
        perl -ne "BEGIN{ print '{\"full_description\":\"';} END{ print '\"}' } s#\n#\\\n#msg;s#\"#\\\\\"#msg;print;" "$2" | \
        curl -s \
             -H "Content-Type: application/json" \
             -H "Authorization: JWT ${TOKEN}" \
             -X PATCH \
             -d@/dev/stdin \
             "https://hub.docker.com/v2/repositories/$1/"
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
    
    TMPDR="$(mktemp -d)"
    git config --global user.email "travis@travis-ci.org"
    git config --global user.name  "Travis CI"
    git clone "$1" "${TMPDR}" >/dev/null 2>&1
    if [ ! -z "$2" ] ; then
        pushd "${TMPDR}" >/dev/null || exit 1
        git checkout "$2"
        popd >/dev/null
    fi
    echo "${TMPDR}"
}

#
# Argument: $1 = repository name. e.g. madworx/docshell.
#
# Outputs the temporary directory name you're supposed to put the Wiki
# files into.
#
github_wiki_prepare() {
    TMPDIR=$(_github_doc_prepare "https://${GH_TOKEN}@github.com/${1}.wiki.git") || exit 1
    pushd "${TMPDR}" >/dev/null || exit 1
    git rm -r . >/dev/null 2>&1 || true
    popd >/dev/null
    echo "${TMPDR}"
}

#
# Argument: $1 = repository name. e.g. madworx/docshell.
#
# Outputs the temporary directory of the gh-pages branch.
#
github_pages_prepare() {
    _github_doc_prepare "https://${GH_TOKEN}@github.com/${1}" "gh-pages" || exit 1
}

#
# Argument:   $1  =   temporary  directory   from  previous   call  to
#                     github_doc_prepare.
#
# Commit previously prepared documentation
#
github_doc_commit() {
    cd "$1" || exit 1
    git add -A .
    git commit -m 'Automated documentation update' -a || return 0
    git push
}

#
# Argument:   $1  =   temporary  directory   from  previous   call  to
#                     github_wiki_prepare.
#
# Commit previously prepared wiki directory.
#
github_wiki_commit() {
    github_doc_commit "$1"
}

