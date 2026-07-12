#!/usr/bin/env bats

setup() {
  export TEST_ROOT="$BATS_TEST_TMPDIR/root"
  export HOME="$TEST_ROOT/home"
  export TEST_REMOTE="$TEST_ROOT/remote.git"
  export REAL_GIT
  REAL_GIT=$(command -v git)

  mkdir -p "$HOME"
  "$REAL_GIT" init --bare --initial-branch=master "$TEST_REMOTE"

  "$REAL_GIT" init --initial-branch=master "$TEST_ROOT/seed"
  configure_repo "$TEST_ROOT/seed"
  printf 'base\n' >"$TEST_ROOT/seed/value"
  "$REAL_GIT" -C "$TEST_ROOT/seed" add value
  "$REAL_GIT" -C "$TEST_ROOT/seed" commit -m base
  "$REAL_GIT" -C "$TEST_ROOT/seed" remote add origin "$TEST_REMOTE"
  "$REAL_GIT" -C "$TEST_ROOT/seed" push --set-upstream origin master

  "$REAL_GIT" config --global url."$TEST_REMOTE".insteadOf git@github.com:booxter/dotfiles.git
}

configure_repo() {
  "$REAL_GIT" -C "$1" config user.name Test
  "$REAL_GIT" -C "$1" config user.email test@example.com
}

sync_repo() {
  "$SYNC_REPO_BIN" dotfiles
}

@test "sync-repo clones a missing repository" {
  run sync_repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned dotfiles into $HOME/.priv-bin"* ]]
  [ "$("$REAL_GIT" -C "$HOME/.priv-bin" rev-parse HEAD)" = "$("$REAL_GIT" --git-dir="$TEST_REMOTE" rev-parse master)" ]
}

@test "sync-repo rebases incoming commits and pushes local commits" {
  sync_repo
  configure_repo "$HOME/.priv-bin"

  "$REAL_GIT" clone "$TEST_REMOTE" "$TEST_ROOT/other"
  configure_repo "$TEST_ROOT/other"
  printf 'remote\n' >"$TEST_ROOT/other/remote"
  "$REAL_GIT" -C "$TEST_ROOT/other" add remote
  "$REAL_GIT" -C "$TEST_ROOT/other" commit -m remote
  "$REAL_GIT" -C "$TEST_ROOT/other" push

  printf 'local\n' >"$HOME/.priv-bin/local"
  "$REAL_GIT" -C "$HOME/.priv-bin" add local
  "$REAL_GIT" -C "$HOME/.priv-bin" commit -m local

  run sync_repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"pushed dotfiles from $HOME/.priv-bin"* ]]
  [ "$("$REAL_GIT" -C "$HOME/.priv-bin" rev-parse HEAD)" = "$("$REAL_GIT" --git-dir="$TEST_REMOTE" rev-parse master)" ]
  [ "$("$REAL_GIT" -C "$HOME/.priv-bin" log -1 --format=%s)" = local ]
}

@test "sync-repo leaves a failed rebase for manual resolution" {
  sync_repo
  configure_repo "$HOME/.priv-bin"

  "$REAL_GIT" clone "$TEST_REMOTE" "$TEST_ROOT/other"
  configure_repo "$TEST_ROOT/other"
  printf 'remote\n' >"$TEST_ROOT/other/value"
  "$REAL_GIT" -C "$TEST_ROOT/other" add value
  "$REAL_GIT" -C "$TEST_ROOT/other" commit -m remote
  "$REAL_GIT" -C "$TEST_ROOT/other" push

  printf 'local\n' >"$HOME/.priv-bin/value"
  "$REAL_GIT" -C "$HOME/.priv-bin" add value
  "$REAL_GIT" -C "$HOME/.priv-bin" commit -m local

  run sync_repo

  [ "$status" -ne 0 ]
  [[ "$output" == *"rebase failed in $HOME/.priv-bin; resolve it there manually"* ]]
  [ -d "$HOME/.priv-bin/.git/rebase-merge" ]
}

@test "sync-repo rejects unknown and removed repository names" {
  for name in unknown notes vault; do
    run "$SYNC_REPO_BIN" "$name"

    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown repository: $name"* ]]
  done
}
