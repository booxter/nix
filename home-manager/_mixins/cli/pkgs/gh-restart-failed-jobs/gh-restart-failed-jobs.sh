#!/usr/bin/env bash

usage() {
  cat <<'EOF'
Usage: gh-restart-failed-jobs <pull-request-url>
       gh-restart-failed-jobs <owner/repository> <pull-request-number>
       gh-restart-failed-jobs <repository> <pull-request-number>
       gh-restart-failed-jobs --all

Restart failed GitHub Actions jobs in every workflow run for a pull request.
With --all, confirm and process all open pull requests in repositories owned by
the authenticated GitHub user.
EOF
}

restart_pull_request() {
  local repo=$1
  local pull_target=$2
  local pull_number=$3
  local check_status=0
  local checks_json
  local count
  local rerun_status
  local run_id
  local run_ids

  checks_json=$(
    gh pr checks "$pull_target" \
      --repo "$repo" \
      --json bucket,link
  ) || check_status=$?

  # Failed or pending checks make `gh pr checks` return 1 or 8 even when it
  # successfully returns the check data.
  case $check_status in
    0 | 1 | 8) ;;
    *) return "$check_status" ;;
  esac

  if [[ -z $checks_json ]] || ! jq -e 'type == "array"' >/dev/null <<<"$checks_json"; then
    printf 'gh-restart-failed-jobs: %s#%s: gh did not return pull request check data\n' \
      "$repo" "$pull_number" >&2
    if ((check_status == 0)); then
      return 1
    fi
    return "$check_status"
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
  ) || return $?

  if [[ -z $run_ids ]]; then
    printf 'gh-restart-failed-jobs: %s#%s: no failed GitHub Actions jobs found\n' \
      "$repo" "$pull_number"
    return 0
  fi

  count=0
  while IFS= read -r run_id; do
    printf 'gh-restart-failed-jobs: %s#%s: restarting failed jobs in workflow run %s\n' \
      "$repo" "$pull_number" "$run_id"
    rerun_status=0
    gh run rerun "$run_id" --failed --repo "$repo" || rerun_status=$?
    if ((rerun_status != 0)); then
      return "$rerun_status"
    fi
    count=$((count + 1))
  done <<<"$run_ids"

  printf 'gh-restart-failed-jobs: %s#%s: restarted failed jobs in %d workflow run(s)\n' \
    "$repo" "$pull_number" "$count"
}

process_all_pull_requests() {
  local answer
  local count
  local failed
  local index
  local number
  local owner
  local owner_status=0
  local prs_json
  local repo
  local search_status=0
  local status
  local title
  local url

  owner=$(gh api user --jq .login) || owner_status=$?
  if ((owner_status != 0)); then
    return "$owner_status"
  fi

  prs_json=$(
    gh search prs \
      --owner "$owner" \
      --state open \
      --limit 1000 \
      --sort updated \
      --order desc \
      --json repository,number,title,url
  ) || search_status=$?
  if ((search_status != 0)); then
    return "$search_status"
  fi

  if [[ -z $prs_json ]] || ! jq -e 'type == "array"' >/dev/null <<<"$prs_json"; then
    printf 'gh-restart-failed-jobs: gh did not return open pull request data\n' >&2
    return 1
  fi

  count=$(jq 'length' <<<"$prs_json") || return $?
  if ((count == 0)); then
    printf 'gh-restart-failed-jobs: no open pull requests found for %s\n' "$owner"
    return 0
  fi

  printf 'gh-restart-failed-jobs: found %d open pull request(s) for %s:\n' "$count" "$owner"
  jq -r '
    to_entries[]
    | "  \(.key + 1). \(.value.repository.nameWithOwner)#\(.value.number) \(.value.title)\n     \(.value.url)"
  ' <<<"$prs_json"

  printf 'Process all %d open pull request(s)? [y/N] ' "$count" >&2
  answer=
  IFS= read -r answer || true
  case $answer in
    y | Y | [Yy][Ee][Ss]) ;;
    *)
      printf 'gh-restart-failed-jobs: cancelled\n'
      return 0
      ;;
  esac

  failed=0
  index=0
  while IFS=$'\t' read -r repo number title url; do
    index=$((index + 1))
    printf 'gh-restart-failed-jobs: [%d/%d] processing %s#%s: %s\n' \
      "$index" "$count" "$repo" "$number" "$title"
    printf 'gh-restart-failed-jobs: [%d/%d] %s\n' "$index" "$count" "$url"

    status=0
    restart_pull_request "$repo" "$number" "$number" || status=$?
    if ((status != 0)); then
      failed=$((failed + 1))
      printf 'gh-restart-failed-jobs: [%d/%d] %s#%s failed with status %d\n' \
        "$index" "$count" "$repo" "$number" "$status" >&2
    fi
  done < <(
    jq -r '
      .[]
      | [.repository.nameWithOwner, (.number | tostring), .title, .url]
      | @tsv
    ' <<<"$prs_json"
  )

  printf 'gh-restart-failed-jobs: processed %d pull request(s): %d succeeded, %d failed\n' \
    "$count" "$((count - failed))" "$failed"
  if ((failed != 0)); then
    return 1
  fi
}

case $# in
  1)
    if [[ $1 == --all ]]; then
      process_all_pull_requests
      exit $?
    fi

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

restart_pull_request "$repo" "$pull_target" "$pull_number"
