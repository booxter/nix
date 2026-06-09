#!/usr/bin/env bash
# shellcheck shell=bash

canonical_secret_host() {
  local repo_root="$1"
  local machine="$2"

  if [[ -f "${repo_root}/secrets/${machine}.yaml" ]]; then
    printf '%s\n' "${machine}"
    return
  fi

  printf '%s\n' "${machine}"
}
