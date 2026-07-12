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

  "$REAL_GIT" config --global url."$TEST_REMOTE".insteadOf git@github.com:booxter/notes.git
}

configure_repo() {
  "$REAL_GIT" -C "$1" config user.name Test
  "$REAL_GIT" -C "$1" config user.email test@example.com
}

sync_repo() {
  "$SYNC_REPO_BIN" notes
}

@test "sync-repo clones a missing repository" {
  run sync_repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned notes into $HOME/notes"* ]]
  [ "$("$REAL_GIT" -C "$HOME/notes" rev-parse HEAD)" = "$("$REAL_GIT" --git-dir="$TEST_REMOTE" rev-parse master)" ]
}

@test "sync-repo rebases incoming commits and pushes local commits" {
  sync_repo
  configure_repo "$HOME/notes"

  "$REAL_GIT" clone "$TEST_REMOTE" "$TEST_ROOT/other"
  configure_repo "$TEST_ROOT/other"
  printf 'remote\n' >"$TEST_ROOT/other/remote"
  "$REAL_GIT" -C "$TEST_ROOT/other" add remote
  "$REAL_GIT" -C "$TEST_ROOT/other" commit -m remote
  "$REAL_GIT" -C "$TEST_ROOT/other" push

  printf 'local\n' >"$HOME/notes/local"
  "$REAL_GIT" -C "$HOME/notes" add local
  "$REAL_GIT" -C "$HOME/notes" commit -m local

  run sync_repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"pushed notes from $HOME/notes"* ]]
  [ "$("$REAL_GIT" -C "$HOME/notes" rev-parse HEAD)" = "$("$REAL_GIT" --git-dir="$TEST_REMOTE" rev-parse master)" ]
  [ "$("$REAL_GIT" -C "$HOME/notes" log -1 --format=%s)" = local ]
}

@test "sync-repo leaves a failed rebase for manual resolution" {
  sync_repo
  configure_repo "$HOME/notes"

  "$REAL_GIT" clone "$TEST_REMOTE" "$TEST_ROOT/other"
  configure_repo "$TEST_ROOT/other"
  printf 'remote\n' >"$TEST_ROOT/other/value"
  "$REAL_GIT" -C "$TEST_ROOT/other" add value
  "$REAL_GIT" -C "$TEST_ROOT/other" commit -m remote
  "$REAL_GIT" -C "$TEST_ROOT/other" push

  printf 'local\n' >"$HOME/notes/value"
  "$REAL_GIT" -C "$HOME/notes" add value
  "$REAL_GIT" -C "$HOME/notes" commit -m local

  run sync_repo

  [ "$status" -ne 0 ]
  [[ "$output" == *"rebase failed in $HOME/notes; resolve it there manually"* ]]
  [ -d "$HOME/notes/.git/rebase-merge" ]
}

@test "sync-repo rejects unknown names" {
  run "$SYNC_REPO_BIN" unknown

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown repository: unknown"* ]]
}
