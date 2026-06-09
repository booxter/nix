#!/usr/bin/env bash
# shellcheck shell=bash

short_prox_vm_name() {
  local machine="$1"
  if [[ "${machine}" == prox-*vm ]]; then
    machine="${machine#prox-}"
    machine="${machine%vm}"
  fi
  printf '%s\n' "${machine}"
}

canonical_secret_host() {
  local repo_root="$1"
  local machine="$2"
  local short_machine

  short_machine="$(short_prox_vm_name "${machine}")"

  if [[ -f "${repo_root}/secrets/${machine}.yaml" ]]; then
    printf '%s\n' "${machine}"
    return
  fi

  if [[ "${short_machine}" != "${machine}" && -f "${repo_root}/secrets/${short_machine}.yaml" ]]; then
    printf '%s\n' "${short_machine}"
    return
  fi

  printf '%s\n' "${machine}"
}
