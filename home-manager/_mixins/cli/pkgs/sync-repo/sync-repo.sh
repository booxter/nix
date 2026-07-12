#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: sync-repo <name>

Synchronize one of: gmailctl, pass, dotfiles.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

name=$1
case "$name" in
  gmailctl)
    remote=git@github.com:booxter/gmailctl-private-config.git
    repo_dir=$HOME/.gmailctl
    ;;
  pass)
    remote=git@github.com:booxter/pass.git
    repo_dir=${PASSWORD_STORE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/password-store}
    ;;
  dotfiles)
    remote=git@github.com:booxter/dotfiles.git
    repo_dir=$HOME/.priv-bin
    ;;
  *)
    printf 'sync-repo: unknown repository: %s\n' "$name" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ ! -e $repo_dir ]]; then
  mkdir -p "$(dirname "$repo_dir")"
  git clone "$remote" "$repo_dir"
  printf 'sync-repo: cloned %s into %s\n' "$name" "$repo_dir"
  exit 0
fi

if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'sync-repo: %s is not a Git repository: %s\n' "$name" "$repo_dir" >&2
  exit 1
fi

if ! branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD); then
  printf 'sync-repo: detached HEAD in %s; fix it manually\n' "$repo_dir" >&2
  exit 1
fi

git -C "$repo_dir" fetch --prune origin

if upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
  :
elif git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  git -C "$repo_dir" branch --set-upstream-to="origin/$branch" "$branch" >/dev/null
  upstream=origin/$branch
else
  git -C "$repo_dir" push --set-upstream origin "$branch"
  printf 'sync-repo: pushed %s from %s\n' "$name" "$repo_dir"
  exit 0
fi

read -r ahead behind < <(git -C "$repo_dir" rev-list --left-right --count "HEAD...$upstream")

if ((behind > 0)); then
  if git -C "$repo_dir" rebase "$upstream"; then
    :
  else
    status=$?
    printf 'sync-repo: rebase failed in %s; resolve it there manually\n' "$repo_dir" >&2
    exit "$status"
  fi
fi

read -r ahead _ < <(git -C "$repo_dir" rev-list --left-right --count "HEAD...$upstream")
if ((ahead > 0)); then
  git -C "$repo_dir" push
  printf 'sync-repo: pushed %s from %s\n' "$name" "$repo_dir"
else
  printf 'sync-repo: %s is up to date in %s\n' "$name" "$repo_dir"
fi
