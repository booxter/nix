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

  if [[ -f "${repo_root}/secrets/${machine}.yaml" ]]; then
    printf '%s\n' "${machine}"
    return
  fi

  local prox_machine="prox-${machine}vm"
  if [[ -f "${repo_root}/secrets/${prox_machine}.yaml" ]]; then
    printf '%s\n' "${prox_machine}"
    return
  fi

  printf '%s\n' "${machine}"
}
