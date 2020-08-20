#!/usr/bin/env bats
# -*- mode: sh -*-

load ../src/cd-ci-glue

DOCKER_ARTIFACTORY="docker.bintray.io/jfrog/artifactory-oss:latest"
ARTIFACTORY_PORT=8081
ARTIFACTORY_ADMIN_PORT=8082

if ! docker inspect artifactory > /dev/null 2>&1 ; then
    echo -n "Starting local version of Artifactory..." 1>&2
    docker kill artifactory > /dev/null 2>&1 || true
    docker run --rm --name artifactory -d -p ${ARTIFACTORY_PORT}-${ARTIFACTORY_ADMIN_PORT}:${ARTIFACTORY_PORT}-${ARTIFACTORY_ADMIN_PORT} \
        "${DOCKER_ARTIFACTORY}" > /dev/null 2>&1
    echo -n "Waiting until Artifactory has fully started..." 1>&2
    (while ! curl -sfL http://localhost:${ARTIFACTORY_ADMIN_PORT}/artifactory > /dev/null ; do
        echo -n "."
        sleep 1
    done ; true)
    echo "done."
fi

@test "Prerequisite: We should not have the jfrog CLI installed" {
    ! type -p ./jfrog && true || exit 1
    ! type -p jfrog && true || exit 1
}

@test "Download jfrog from incorrect URL should fail" {
    export _JFROG_INSTALL_URL='http://www.example.com/this-download-doesnt-exist'
    run _artifactory_ensure_cli
    echo $output
    echo $status
    [ "$status" -eq 1 ]
}

@test "Existing jfrog binary should be used if exists" {
    echo -e "#!/bin/sh\necho dummy-output" > "${BATS_TMPDIR}/jfrog"
    chmod +x "${BATS_TMPDIR}/jfrog"
    PATH="${BATS_TMPDIR}:${PATH}"
    CLICMD=$(_artifactory_ensure_cli) || exit 1
    run $CLICMD
    [ "$status" -eq 0 ] && [ "$output" == "dummy-output" ]
}

@test "Setup artifactory without environment should fail" {
    unset ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_PASSWORD
    run artifactory_setup
    [ "$status" -eq 1 ]
}

@test "Setup artifactory with incorrect credentials should fail" {
    ARTIFACTORY_URL=http://localhost:${ARTIFACTORY_PORT}/artifactory/
    ARTIFACTORY_USER=admin 
    ARTIFACTORY_PASSWORD=passxword
    run artifactory_setup
    [ "$status" -eq 1 ]
}

@test "Setup artifactory with correct credentials should work" {
    ARTIFACTORY_URL=http://localhost:${ARTIFACTORY_PORT}/artifactory/
    ARTIFACTORY_USER=admin 
    ARTIFACTORY_PASSWORD=password
    run artifactory_setup
    [ "$status" -eq 0 ]
}

