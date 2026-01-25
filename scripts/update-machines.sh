#!/usr/bin/env nix-shell
#!nix-shell -i bash -p jq bind python3 python3Packages.prompt-toolkit
# shellcheck shell=bash
set -euo pipefail

REPO_URL="github.com:booxter/nix"
BRANCH="master"
ALL=true
MODE="personal"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLOR_RESET='\033[0m'
COLOR_HOST='\033[1;36m'
COLOR_BLUE='\033[1;34m'
COLOR_DIM='\033[2m'
COLOR_GREEN='\033[1;32m'
COLOR_RED='\033[1;31m'
LAN_DNS_SERVER="192.168.1.1"
WORK_MAP=""
DRY_RUN=false
SELECT=false
START_TS="$(date +%s)"

resolve_ssh_host() {
  local host="$1"
  local base_host
  case "$host" in
    pi5)
      # TODO: add DNS alias so "pi5" resolves, then remove this mapping.
      base_host="dhcp"
      ;;
    *)
      base_host="$host"
      ;;
  esac

  if [[ "$MODE" == "work" || "$MODE" == "both" ]]; then
    local is_work
    is_work="$(jq -r --arg h "$host" '(.nixos[$h] // .darwin[$h] // "unknown")' <<<"$WORK_MAP" 2>/dev/null || echo "unknown")"
    if [[ "$is_work" == "true" ]]; then
      resolved="$(dig +short "@${LAN_DNS_SERVER}" "$base_host" A | head -n1)"
      if [[ -n "$resolved" ]]; then
        printf '%s' "$resolved"
        return
      fi
    fi
  fi

  printf '%s' "$base_host"
}

ssh_base_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=8
)

run_selector() {
  local -a items=("$@")
  local tmpfile selection
  tmpfile="$(mktemp)"
  printf '%s\n' "${items[@]}" >"$tmpfile"
  if ! selection="$(python3 "${REPO_ROOT}/scripts/selector.py" --file "$tmpfile")"; then
    rm -f "$tmpfile"
    echo "Selection canceled." >&2
    exit 1
  fi
  rm -f "$tmpfile"
  printf '%s' "$selection"
}

print_summary_box() {
  local total="$1"
  local ok="$2"
  local failed="$3"
  local elapsed="$4"
  local failed_list="$5"
  local minutes seconds duration_fmt

  minutes=$((elapsed / 60))
  seconds=$((elapsed % 60))
  duration_fmt="${minutes}m ${seconds}s"

  summary_text="Update Summary
Total: ${total}  Succeeded: ${ok}  Failed: ${failed}
Duration: ${duration_fmt}"
  if [[ -n "$failed_list" ]]; then
    summary_text="${summary_text}
Failed hosts: ${failed_list}"
  fi

  border_color=2
  text_color=2
  if ((failed > 0)); then
    border_color=1
    text_color=1
  fi
  printf '%s\n' "$summary_text" | python3 "${REPO_ROOT}/scripts/box.py" \
    --border-color "$border_color" \
    --text-color "$text_color" \
    --margin "1 2" \
    --padding "1 2" \
    --border double \
    --align center
}

SSH_OPTS_ARR=()
if [[ -n "${SSH_OPTS:-}" ]]; then
  # Allow passing multiple SSH options via a single string.
  read -r -a SSH_OPTS_ARR <<<"${SSH_OPTS}"
fi

usage() {
  cat <<'EOF'
Usage:
  scripts/update-machines.sh [-A|--all] [--branch BRANCH] [--personal|--work|--both]
  scripts/update-machines.sh [--branch BRANCH] [--personal|--work|--both] [--dry-run] [--select] host1 [host2 ...]

Options:
  -A, --all         Update all hosts discovered from flake outputs (default).
  --personal        Update only personal machines (default).
  --work            Update only work machines.
  --both            Update all machines (work + personal).
  --branch BRANCH   Git branch to deploy (default: master).
  --dry-run         Only check SSH and print the hosts that would be updated.
  --select          Interactively select hosts from the filtered list.

Notes:
  - Passing explicit host names disables --all.
  -h, --help        Show this help.

Environment:
  SSH_OPTS          Extra args passed to ssh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -A|--all)
      ALL=true
      shift
      ;;
    --branch)
      BRANCH="${2:-}"
      if [[ -z "$BRANCH" ]]; then
        echo "Missing value for --branch" >&2
        exit 1
      fi
      shift 2
      ;;
    --work)
      MODE="work"
      shift
      ;;
    --personal)
      MODE="personal"
      shift
      ;;
    --both)
      MODE="both"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --select)
      SELECT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ "$MODE" != "personal" && "$MODE" != "work" && "$MODE" != "both" ]]; then
  echo "Invalid mode: $MODE" >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  ALL=false
fi

if [[ "$ALL" == "true" && "$SELECT" == "false" ]]; then
  SELECT=true
fi

if [[ "$ALL" == "true" ]]; then
  if [[ $# -gt 0 ]]; then
    echo "Do not pass host names with -A." >&2
    exit 1
  fi
  WORK_MAP="$("${REPO_ROOT}/scripts/get-hosts.sh" 2>/dev/null || echo '')"
  if [[ -z "$WORK_MAP" ]]; then
    echo "Failed to read hosts from get-hosts.sh." >&2
    exit 1
  fi
  mapfile -t HOSTS < <(
    jq -r '
      [
        (.nixos | keys[]),
        (.darwin | keys[])
      ]
      | unique
      | sort
      | .[]
    ' <<<"$WORK_MAP"
  )
else
  if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
  fi
  HOSTS=("$@")
  SELECT=false
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "No hosts selected." >&2
  exit 1
fi

if [[ "$MODE" != "both" ]]; then
  if [[ -z "$WORK_MAP" ]]; then
    WORK_MAP="$("${REPO_ROOT}/scripts/get-hosts.sh" 2>/dev/null || echo '')"
    if [[ -z "$WORK_MAP" ]]; then
      echo "Failed to read work status map from flake." >&2
      exit 1
    fi
  fi
fi

if [[ "$MODE" != "both" ]]; then
  filtered=()
  for host in "${HOSTS[@]}"; do
    is_work="$(jq -r --arg h "$host" '(.nixos[$h] // .darwin[$h] // "null")' <<<"$WORK_MAP")"
    if [[ -z "$is_work" || "$is_work" == "null" ]]; then
      is_work="false"
    fi
    if [[ "$MODE" == "work" && "$is_work" == "true" ]] || [[ "$MODE" == "personal" && "$is_work" == "false" ]]; then
      filtered+=("$host")
    fi
  done
  HOSTS=("${filtered[@]}")
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "No hosts selected after applying mode '$MODE'." >&2
  exit 1
fi

if [[ "$SELECT" == "true" ]]; then
  mapfile -t sorted_hosts < <(printf '%s\n' "${HOSTS[@]}" | LC_ALL=C sort)
  selection="$(run_selector "${sorted_hosts[@]}")"
  if [[ -z "$selection" ]]; then
    echo "No selection made." >&2
    exit 1
  fi
  mapfile -t selected <<<"$selection"
  HOSTS=("${selected[@]}")
fi

prioritized=()
deferred=()
normal=()
for host in "${HOSTS[@]}"; do
  if [[ "$host" == "pi5" ]]; then
    prioritized+=("$host")
  elif [[ "$host" =~ ^prx[0-9]+-lab$ || "$host" == "nvws" ]]; then
    prioritized+=("$host")
  elif [[ "$host" == *cachevm* ]]; then
    deferred+=("$host")
  else
    normal+=("$host")
  fi
done
HOSTS=("${prioritized[@]}" "${normal[@]}" "${deferred[@]}")

echo "Checking SSH connectivity to ${#HOSTS[@]} hosts..."
failed=0
host_status_lines=()
for host in "${HOSTS[@]}"; do
  ssh_host="$(resolve_ssh_host "$host")"
  if ssh "${ssh_base_opts[@]}" "${SSH_OPTS_ARR[@]}" "$ssh_host" true >/dev/null 2>&1; then
    ok="ok"
  else
    ok="failed"
    failed=$((failed + 1))
  fi

  avail_gb=""
  if [[ "$DRY_RUN" == "true" && "$ok" == "ok" ]]; then
    avail_gb="$(ssh "${ssh_base_opts[@]}" "${SSH_OPTS_ARR[@]}" "$ssh_host" "df -Pk \"\$HOME\" | awk 'NR==2 {printf \"%.1f\", \$4/1024/1024}'" 2>/dev/null || true)"
    if [[ -z "$avail_gb" ]]; then
      avail_gb="unknown"
    fi
  fi

  status_color="$COLOR_GREEN"
  if [[ "$ok" != "ok" ]]; then
    status_color="$COLOR_RED"
  fi
  line="- ${COLOR_BLUE}${host}${COLOR_RESET} (${COLOR_DIM}${ssh_host}${COLOR_RESET}): ${status_color}${ok}${COLOR_RESET}"
  if [[ -n "$avail_gb" ]]; then
    line="${line}, ${avail_gb} GiB"
  fi
  host_status_lines+=("$line")
done

printf '%b\n' "${host_status_lines[@]}"

if [[ $failed -ne 0 ]]; then
  echo "Aborting: $failed host(s) unreachable." >&2
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run: would update ${#HOSTS[@]} host(s)."
  exit 0
fi

ok_hosts=()
failed_hosts=()
for host in "${HOSTS[@]}"; do
  ssh_host="$(resolve_ssh_host "$host")"
  printf '%b\n' "${COLOR_HOST}==> ${host}${COLOR_RESET}"
  if ! [ -t 0 ]; then
    echo "Error: no TTY available for sudo on ${host}. Run this script from a real terminal." >&2
    exit 1
  fi
  remote_script="/tmp/update-nix-$$.sh"
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS_ARR[@]}" "$ssh_host" "cat > \"$remote_script\" && chmod +x \"$remote_script\"" <<'REMOTE'
set -euo pipefail
trap 'rm -f "$0"' EXIT
branch="$1"
repo_url="$2"
repo_dir="$(mktemp -d)"
trap 'rm -rf "$repo_dir"' EXIT

format_avail_gib() {
  AVAIL_KB="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
  if [[ -z "$AVAIL_KB" ]]; then
    return 1
  fi
  awk "BEGIN {printf \"%.1f\", ${AVAIL_KB}/1024/1024}"
}

AVAIL_KB=""
avail_gb="$(format_avail_gib || true)"
if [[ -n "$avail_gb" ]]; then
  printf '\033[1;33m%s\033[0m\n' "Available disk: ${avail_gb} GiB"
fi
if [[ -n "$AVAIL_KB" && "$AVAIL_KB" -lt 20971520 ]]; then
  echo "Low disk space (<20GiB). Running nix-collect-garbage -d..."
  sudo nix-collect-garbage -d
  avail_gb_after="$(format_avail_gib || true)"
  if [[ -n "$avail_gb_after" ]]; then
    printf '\033[1;33m%s\033[0m\n' "Available disk after cleanup: ${avail_gb_after} GiB"
  fi
fi

https_url="https://github.com/${repo_url#github.com:}.git"
git clone --branch "$branch" --single-branch "$https_url" "$repo_dir"

cd "$repo_dir"

if make -n switch >/dev/null 2>&1; then
  make switch
else
  os="$(uname -s)"
  # TODO: remove once all machines have the switch target.
  case "$os" in
    Darwin)
      make darwin-switch
      ;;
    Linux)
      make nixos-switch
      ;;
    *)
      echo "Unsupported OS: $os" >&2
      exit 1
      ;;
  esac
fi
REMOTE
  if ssh -tt "${SSH_OPTS_ARR[@]}" "$ssh_host" "$remote_script" "$BRANCH" "$REPO_URL"; then
    ok_hosts+=("$host")
  else
    failed_hosts+=("$host")
  fi
done

END_TS="$(date +%s)"
elapsed=$((END_TS - START_TS))
printf '\n'

failed_list=""
if [[ ${#failed_hosts[@]} -gt 0 ]]; then
  failed_list="$(printf '%s' "${failed_hosts[*]}")"
fi
print_summary_box "${#HOSTS[@]}" "${#ok_hosts[@]}" "${#failed_hosts[@]}" "$elapsed" "$failed_list"
