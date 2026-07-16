#!/usr/bin/env bash

# shellcheck disable=SC2088 # Expanded deliberately by expand_home below.
default_roots=(
  @roots@
)

warn() {
  printf 'sync-git-mains: warning: %s\n' "$*" >&2
}

expand_home() {
  case "$1" in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

checked_out_worktree() {
  local repo=$1
  local branch=$2
  local key value worktree=

  while IFS=' ' read -r key value; do
    case "$key" in
      worktree) worktree=$value ;;
      branch)
        if [[ $value == "refs/heads/$branch" ]]; then
          printf '%s\n' "$worktree"
          return 0
        fi
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)

  return 1
}

sync_repository() {
  local repo=$1
  local origin_head branch remote_head remote_ref local_ref remote_oid local_oid worktree

  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    return 0
  fi

  if origin_head=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD); then
    case "$origin_head" in
      origin/main) branch=main ;;
      origin/master) branch=master ;;
      *) return 0 ;;
    esac
  elif ! remote_head=$(git -C "$repo" ls-remote --symref origin HEAD); then
    warn "failed to determine origin's default branch: $repo"
    return 1
  else
    remote_head=${remote_head%%$'\n'*}
    if [[ $remote_head =~ ^ref:[[:space:]]+refs/heads/(main|master)[[:space:]]+HEAD$ ]]; then
      branch=${BASH_REMATCH[1]}
    else
      return 0
    fi
  fi

  local_ref="refs/heads/$branch"
  if ! local_oid=$(git -C "$repo" rev-parse --verify "$local_ref" 2>/dev/null); then
    return 0
  fi

  if ! git -C "$repo" fetch --prune origin "$branch"; then
    warn "fetch from origin failed: $repo"
    return 1
  fi

  remote_ref="refs/remotes/origin/$branch"
  if ! remote_oid=$(git -C "$repo" rev-parse --verify "$remote_ref"); then
    warn "origin/$branch was not fetched: $repo"
    return 1
  fi

  if [[ $local_oid == "$remote_oid" ]]; then
    return 0
  fi
  if ! git -C "$repo" merge-base --is-ancestor "$local_oid" "$remote_oid"; then
    warn "$branch cannot be fast-forwarded to origin/$branch in $repo"
    return 1
  fi

  if worktree=$(checked_out_worktree "$repo" "$branch"); then
    if [[ -n $(git -C "$worktree" status --porcelain) ]]; then
      warn "$branch is checked out with a dirty worktree; not updating $repo"
      return 1
    fi
    if ! git -C "$worktree" merge --ff-only "$remote_ref"; then
      warn "fast-forward failed in worktree $worktree"
      return 1
    fi
  elif ! git -C "$repo" update-ref "$local_ref" "$remote_oid" "$local_oid"; then
    warn "$branch changed while it was being updated in $repo"
    return 1
  fi

  printf 'sync-git-mains: advanced %s to origin/%s in %s\n' "$branch" "$branch" "$repo"
}

sync_root() {
  local configured_root=$1
  local root repo

  root=$(expand_home "$configured_root")
  if [[ ! -d $root ]]; then
    warn "source root does not exist: $root"
    return 1
  fi

  for repo in "$root"/*; do
    [[ -d $repo ]] || continue
    if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
      sync_repository "$repo" || status=1
    fi
  done
}

shopt -s dotglob nullglob
if (($# > 0)); then
  roots=("$@")
else
  roots=("${default_roots[@]}")
fi

status=0
for root in "${roots[@]}"; do
  if ! sync_root "$root"; then
    status=1
  fi
done
exit "$status"
