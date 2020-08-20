#!/usr/bin/env bats
# -*- mode: sh -*-

load ../src/cd-ci-glue

@test "CLI utility 'jq' should be installed" {
  _ensure_jq
}

@test "CLI utility 'jq' not in path should fail" {
  PATH=/tmp run _ensure_jq
  [ "$status" -eq 1 ]
}
