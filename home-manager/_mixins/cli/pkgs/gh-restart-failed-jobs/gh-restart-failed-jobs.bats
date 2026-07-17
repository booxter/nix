#!/usr/bin/env bats

setup() {
  export TEST_ROOT="$BATS_TEST_TMPDIR/root"
  export GH_LOG="$TEST_ROOT/gh.log"
  export GH_CHECKS="$TEST_ROOT/checks.json"
  export GH_PRS="$TEST_ROOT/prs.json"
  mkdir -p "$TEST_ROOT/bin"
  printf '[]\n' >"$GH_PRS"

  printf '#!%s\n' "$BASH" >"$TEST_ROOT/bin/gh"
  cat >>"$TEST_ROOT/bin/gh" <<'EOF'
printf '%s\n' "$*" >>"$GH_LOG"

case "$1 $2" in
  "api user")
    printf '%s\n' "${GH_USER:-booxter}"
    ;;
  "pr checks")
    jq -c . "$GH_CHECKS"
    exit "${GH_CHECKS_STATUS:-1}"
    ;;
  "run rerun")
    if [[ -n ${GH_RERUN_FAILURE_REPO:-} && $* == *"--repo $GH_RERUN_FAILURE_REPO"* ]]; then
      exit "${GH_RERUN_STATUS:-17}"
    fi
    exit "${GH_RERUN_STATUS:-0}"
    ;;
  "search prs")
    jq -c . "$GH_PRS"
    ;;
  *)
    printf 'unexpected gh arguments: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/gh"
  export PATH="$TEST_ROOT/bin:$PATH"
}

restart_failed_jobs() {
  bash -o errexit -o nounset -o pipefail "$GH_RESTART_FAILED_JOBS_BIN" "$@"
}

@test "restarts failed jobs in each distinct Actions workflow run" {
  cat >"$GH_CHECKS" <<'EOF'
[
  {
    "bucket": "fail",
    "link": "https://github.com/acme/widgets/actions/runs/101/job/1001"
  },
  {
    "bucket": "fail",
    "link": "https://github.com/acme/widgets/actions/runs/101/job/1002"
  },
  {
    "bucket": "fail",
    "link": "https://github.com/acme/widgets/actions/runs/202/job/2001"
  },
  {
    "bucket": "fail",
    "link": "https://ci.example.com/acme/widgets/build/303"
  },
  {
    "bucket": "pass",
    "link": "https://github.com/acme/widgets/actions/runs/404/job/4001"
  }
]
EOF

  run restart_failed_jobs "https://github.com/acme/widgets/pull/42/files"

  [ "$status" -eq 0 ]
  [[ "$output" == *"restarted failed jobs in 2 workflow run(s)"* ]]
  grep -Fq \
    "pr checks https://github.com/acme/widgets/pull/42 --repo github.com/acme/widgets --json bucket,link" \
    "$GH_LOG"
  grep -Fqx "run rerun 101 --failed --repo github.com/acme/widgets" "$GH_LOG"
  grep -Fqx "run rerun 202 --failed --repo github.com/acme/widgets" "$GH_LOG"
  [ "$(grep -c '^run rerun ' "$GH_LOG")" -eq 2 ]
}

@test "accepts an owner and repository with a pull request number" {
  cat >"$GH_CHECKS" <<'EOF'
[
  {
    "bucket": "fail",
    "link": "https://github.com/booxter/nix/actions/runs/101/job/1001"
  }
]
EOF

  run restart_failed_jobs "booxter/nix" 42

  [ "$status" -eq 0 ]
  grep -Fqx "pr checks 42 --repo booxter/nix --json bucket,link" "$GH_LOG"
  grep -Fqx "run rerun 101 --failed --repo booxter/nix" "$GH_LOG"
}

@test "uses the authenticated user for an unqualified repository" {
  cat >"$GH_CHECKS" <<'EOF'
[
  {
    "bucket": "fail",
    "link": "https://github.com/booxter/nix/actions/runs/101/job/1001"
  }
]
EOF

  run restart_failed_jobs nix 42

  [ "$status" -eq 0 ]
  grep -Fqx "api user --jq .login" "$GH_LOG"
  grep -Fqx "pr checks 42 --repo booxter/nix --json bucket,link" "$GH_LOG"
  grep -Fqx "run rerun 101 --failed --repo booxter/nix" "$GH_LOG"
}

@test "lists, confirms, and processes all open pull requests" {
  cat >"$GH_PRS" <<'EOF'
[
  {
    "number": 42,
    "repository": {"nameWithOwner": "booxter/nix"},
    "title": "Improve the Nix configuration",
    "url": "https://github.com/booxter/nix/pull/42"
  },
  {
    "number": 7,
    "repository": {"nameWithOwner": "booxter/dotfiles"},
    "title": "Refresh shell aliases",
    "url": "https://github.com/booxter/dotfiles/pull/7"
  }
]
EOF
  cat >"$GH_CHECKS" <<'EOF'
[
  {
    "bucket": "fail",
    "link": "https://github.com/booxter/repository/actions/runs/101/job/1001"
  }
]
EOF

  run restart_failed_jobs --all <<<"yes"

  [ "$status" -eq 0 ]
  [[ "$output" == *"found 2 open pull request(s) for booxter"* ]]
  [[ "$output" == *"1. booxter/nix#42 Improve the Nix configuration"* ]]
  [[ "$output" == *"2. booxter/dotfiles#7 Refresh shell aliases"* ]]
  [[ "$output" == *"Process all 2 open pull request(s)? [y/N]"* ]]
  [[ "$output" == *"[1/2] processing booxter/nix#42"* ]]
  [[ "$output" == *"[2/2] processing booxter/dotfiles#7"* ]]
  [[ "$output" == *"processed 2 pull request(s): 2 succeeded, 0 failed"* ]]
  grep -Fqx \
    "search prs --owner booxter --state open --limit 1000 --sort updated --order desc --json repository,number,title,url" \
    "$GH_LOG"
  grep -Fqx "run rerun 101 --failed --repo booxter/nix" "$GH_LOG"
  grep -Fqx "run rerun 101 --failed --repo booxter/dotfiles" "$GH_LOG"
}

@test "does not process all pull requests without confirmation" {
  cat >"$GH_PRS" <<'EOF'
[
  {
    "number": 42,
    "repository": {"nameWithOwner": "booxter/nix"},
    "title": "Improve the Nix configuration",
    "url": "https://github.com/booxter/nix/pull/42"
  }
]
EOF

  run restart_failed_jobs --all <<<"no"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Process all 1 open pull request(s)? [y/N]"* ]]
  [[ "$output" == *"cancelled"* ]]
  ! grep -q '^pr checks ' "$GH_LOG"
}

@test "continues processing all pull requests after one fails" {
  cat >"$GH_PRS" <<'EOF'
[
  {
    "number": 42,
    "repository": {"nameWithOwner": "booxter/nix"},
    "title": "Improve the Nix configuration",
    "url": "https://github.com/booxter/nix/pull/42"
  },
  {
    "number": 7,
    "repository": {"nameWithOwner": "booxter/dotfiles"},
    "title": "Refresh shell aliases",
    "url": "https://github.com/booxter/dotfiles/pull/7"
  }
]
EOF
  cat >"$GH_CHECKS" <<'EOF'
[
  {
    "bucket": "fail",
    "link": "https://github.com/booxter/repository/actions/runs/101/job/1001"
  }
]
EOF
  export GH_RERUN_FAILURE_REPO=booxter/nix

  run restart_failed_jobs --all <<<"y"

  [ "$status" -eq 1 ]
  [[ "$output" == *"booxter/nix#42 failed with status 17"* ]]
  [[ "$output" == *"[2/2] processing booxter/dotfiles#7"* ]]
  [[ "$output" == *"processed 2 pull request(s): 1 succeeded, 1 failed"* ]]
  grep -Fqx "run rerun 101 --failed --repo booxter/dotfiles" "$GH_LOG"
}

@test "reports when only external checks failed" {
  cat >"$GH_CHECKS" <<'EOF'
[
  {
    "bucket": "fail",
    "link": "https://ci.example.com/acme/widgets/build/303"
  }
]
EOF

  run restart_failed_jobs "https://github.com/acme/widgets/pull/42"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no failed GitHub Actions jobs found"* ]]
  ! grep -q '^run rerun ' "$GH_LOG"
}

@test "does not mask a failed check-data request" {
  : >"$GH_CHECKS"

  run restart_failed_jobs "https://github.com/acme/widgets/pull/42"

  [ "$status" -eq 1 ]
  [[ "$output" == *"gh did not return pull request check data"* ]]
  ! grep -q '^run rerun ' "$GH_LOG"
}

@test "rejects invalid argument forms" {
  run restart_failed_jobs
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: gh-restart-failed-jobs"* ]]

  run restart_failed_jobs "acme/widgets#42"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a GitHub pull request URL"* ]]
}

@test "propagates a workflow rerun failure" {
  cat >"$GH_CHECKS" <<'EOF'
[
  {
    "bucket": "fail",
    "link": "https://github.example.com/acme/widgets/actions/runs/101/job/1001"
  }
]
EOF
  export GH_RERUN_STATUS=17

  run restart_failed_jobs "https://github.example.com/acme/widgets/pull/42"

  [ "$status" -eq 17 ]
  grep -Fqx \
    "run rerun 101 --failed --repo github.example.com/acme/widgets" \
    "$GH_LOG"
}
