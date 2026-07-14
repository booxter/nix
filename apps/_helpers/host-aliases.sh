#!/usr/bin/env bash
# shellcheck shell=bash

canonical_secret_host() {
  local repo_root="$1"
  local domain="$2"
  local machine="$3"

  if [[ -f "${repo_root}/secrets/${domain}/${machine}.yaml" ]]; then
    printf '%s\n' "${machine}"
    return
  fi

  printf '%s\n' "${machine}"
}
