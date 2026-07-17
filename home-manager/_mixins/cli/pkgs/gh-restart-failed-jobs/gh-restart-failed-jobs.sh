#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: gh-restart-failed-jobs <pull-request-url>
       gh-restart-failed-jobs <owner/repository> <pull-request-number>
       gh-restart-failed-jobs <repository> <pull-request-number>

Restart failed GitHub Actions jobs in every workflow run for a pull request.
EOF
}

case $# in
  1)
    input_url=$1
    if [[ $input_url =~ ^https://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+)([/?#].*)?$ ]]; then
      host=${BASH_REMATCH[1]}
      owner=${BASH_REMATCH[2]}
      repository=${BASH_REMATCH[3]}
      pull_number=${BASH_REMATCH[4]}
    else
      printf 'gh-restart-failed-jobs: not a GitHub pull request URL: %s\n' "$input_url" >&2
      usage >&2
      exit 2
    fi

    repo=$host/$owner/$repository
    pull_target=https://$repo/pull/$pull_number
    ;;
  2)
    repository_arg=$1
    pull_number=$2
    if [[ ! $pull_number =~ ^[0-9]+$ ]]; then
      printf 'gh-restart-failed-jobs: not a pull request number: %s\n' "$pull_number" >&2
      usage >&2
      exit 2
    fi

    if [[ $repository_arg =~ ^[^/]+/[^/]+$ ]]; then
      repo=$repository_arg
    elif [[ $repository_arg =~ ^[^/]+$ ]]; then
      owner=$(gh api user --jq .login)
      repo=$owner/$repository_arg
    else
      printf 'gh-restart-failed-jobs: not a repository name: %s\n' "$repository_arg" >&2
      usage >&2
      exit 2
    fi
    pull_target=$pull_number
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

check_status=0
checks_json=$(
  gh pr checks "$pull_target" \
    --repo "$repo" \
    --json bucket,link
) || check_status=$?

# Failed or pending checks make `gh pr checks` return 1 or 8 even when it
# successfully returns the check data.
case $check_status in
  0 | 1 | 8) ;;
  *) exit "$check_status" ;;
esac

if [[ -z $checks_json ]] || ! jq -e 'type == "array"' >/dev/null <<<"$checks_json"; then
  printf 'gh-restart-failed-jobs: gh did not return pull request check data\n' >&2
  if ((check_status == 0)); then
    exit 1
  fi
  exit "$check_status"
fi

run_ids=$(
  jq -r '
    [
      .[]
      | select(.bucket == "fail")
      | .link
      | try capture("/actions/runs/(?<id>[0-9]+)").id
    ]
    | unique[]
  ' <<<"$checks_json"
)

if [[ -z $run_ids ]]; then
  printf 'gh-restart-failed-jobs: no failed GitHub Actions jobs found for %s#%s\n' "$repo" "$pull_number"
  exit 0
fi

count=0
while IFS= read -r run_id; do
  printf 'gh-restart-failed-jobs: restarting failed jobs in workflow run %s\n' "$run_id"
  gh run rerun "$run_id" --failed --repo "$repo"
  count=$((count + 1))
done <<<"$run_ids"

printf 'gh-restart-failed-jobs: restarted failed jobs in %d workflow run(s)\n' "$count"
