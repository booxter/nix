#!/usr/bin/env bats

setup() {
  export TEST_ROOT="$BATS_TEST_TMPDIR/root"
  export HOME="$TEST_ROOT/home"
  export REAL_GIT
  REAL_GIT=$(command -v git)
  mkdir -p "$HOME"
}

configure_repo() {
  "$REAL_GIT" -C "$1" config user.name Test
  "$REAL_GIT" -C "$1" config user.email test@example.com
}

make_repository() {
  local name=$1
  local branch=$2
  local remote="$TEST_ROOT/$name.git"
  local seed="$TEST_ROOT/$name-seed"
  local checkout="$HOME/src/$name"

  "$REAL_GIT" init --bare --initial-branch="$branch" "$remote"
  "$REAL_GIT" init --initial-branch="$branch" "$seed"
  configure_repo "$seed"
  printf 'base\n' >"$seed/value"
  "$REAL_GIT" -C "$seed" add value
  "$REAL_GIT" -C "$seed" commit -m base
  "$REAL_GIT" -C "$seed" remote add origin "$remote"
  "$REAL_GIT" -C "$seed" push --set-upstream origin "$branch"
  "$REAL_GIT" clone "$remote" "$checkout"
  configure_repo "$checkout"
}

add_remote_commit() {
  local name=$1
  local filename=${2:-remote}
  local seed="$TEST_ROOT/$name-seed"

  printf 'remote\n' >"$seed/$filename"
  "$REAL_GIT" -C "$seed" add "$filename"
  "$REAL_GIT" -C "$seed" commit -m remote
  "$REAL_GIT" -C "$seed" push
}

sync_repositories() {
  "$SYNC_GIT_MAINS_BIN" "$@"
}

@test "discovers and fast-forwards checked-out main and master branches" {
  make_repository main-repo main
  make_repository master-repo master
  mkdir -p "$HOME/src/not-a-repository"
  "$REAL_GIT" init --initial-branch=main "$HOME/src/no-origin"
  add_remote_commit main-repo
  add_remote_commit master-repo

  run sync_repositories

  [ "$status" -eq 0 ]
  [[ "$output" == *"advanced main to origin/main"* ]]
  [[ "$output" == *"advanced master to origin/master"* ]]
  [ "$("$REAL_GIT" -C "$HOME/src/main-repo" rev-parse main)" = "$("$REAL_GIT" --git-dir="$TEST_ROOT/main-repo.git" rev-parse main)" ]
  [ "$("$REAL_GIT" -C "$HOME/src/master-repo" rev-parse master)" = "$("$REAL_GIT" --git-dir="$TEST_ROOT/master-repo.git" rev-parse master)" ]
}

@test "updates a default branch that is not checked out" {
  make_repository repo main
  "$REAL_GIT" -C "$HOME/src/repo" switch -c feature
  feature_oid=$("$REAL_GIT" -C "$HOME/src/repo" rev-parse HEAD)
  add_remote_commit repo

  run sync_repositories "$HOME/src"

  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$HOME/src/repo" branch --show-current)" = feature ]
  [ "$("$REAL_GIT" -C "$HOME/src/repo" rev-parse HEAD)" = "$feature_oid" ]
  [ "$("$REAL_GIT" -C "$HOME/src/repo" rev-parse main)" = "$("$REAL_GIT" --git-dir="$TEST_ROOT/repo.git" rev-parse main)" ]
}

@test "does not create a missing local default branch" {
  make_repository repo main
  "$REAL_GIT" -C "$HOME/src/repo" switch -c feature
  "$REAL_GIT" -C "$HOME/src/repo" branch -D main
  add_remote_commit repo

  run sync_repositories "$HOME/src"

  [ "$status" -eq 0 ]
  ! "$REAL_GIT" -C "$HOME/src/repo" show-ref --verify --quiet refs/heads/main
}

@test "does not change a diverged default branch" {
  make_repository repo main
  printf 'local\n' >"$HOME/src/repo/local"
  "$REAL_GIT" -C "$HOME/src/repo" add local
  "$REAL_GIT" -C "$HOME/src/repo" commit -m local
  local_oid=$("$REAL_GIT" -C "$HOME/src/repo" rev-parse main)
  add_remote_commit repo

  run sync_repositories "$HOME/src"

  [ "$status" -eq 1 ]
  [[ "$output" == *"main cannot be fast-forwarded to origin/main"* ]]
  [ "$("$REAL_GIT" -C "$HOME/src/repo" rev-parse main)" = "$local_oid" ]
}

@test "does not update a dirty checked-out default branch" {
  make_repository repo master
  add_remote_commit repo remote
  printf 'dirty\n' >"$HOME/src/repo/dirty"
  local_oid=$("$REAL_GIT" -C "$HOME/src/repo" rev-parse master)

  run sync_repositories "$HOME/src"

  [ "$status" -eq 1 ]
  [[ "$output" == *"master is checked out with a dirty worktree"* ]]
  [ "$("$REAL_GIT" -C "$HOME/src/repo" rev-parse master)" = "$local_oid" ]
}

@test "warns about a missing root but continues with the rest" {
  make_repository repo main
  add_remote_commit repo

  run sync_repositories "$HOME/missing" "$HOME/src"

  [ "$status" -eq 1 ]
  [[ "$output" == *"source root does not exist: $HOME/missing"* ]]
  [[ "$output" == *"advanced main to origin/main"* ]]
  [ "$("$REAL_GIT" -C "$HOME/src/repo" rev-parse main)" = "$("$REAL_GIT" --git-dir="$TEST_ROOT/repo.git" rev-parse main)" ]
}
