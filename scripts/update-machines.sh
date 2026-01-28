#!/usr/bin/env nix-shell
#!nix-shell -i bash -p jq bind python3 python3Packages.prompt-toolkit
# shellcheck shell=bash
set -euo pipefail

REPO_URL="github.com:booxter/nix"
BRANCH="master"
ALL=true
MODE="personal"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/_helpers/update-machines-lib.sh"
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
MIN_DISK_GIB=20
MIN_DISK_KB="$(calc_min_disk_kb_from_gib "$MIN_DISK_GIB")"
SSH_HOST_OPTS=()

resolve_ssh_host() {
  local host="$1"
  local base_host
  local ssh_config proxy_jump proxy_cmd
  local resolved
  base_host="$(resolve_base_host "$host")"
  SSH_HOST_OPTS=()

  ssh_config="$(ssh -G "$base_host" 2>/dev/null || true)"
  proxy_jump="$(awk '$1=="proxyjump" {print $2; exit}' <<<"$ssh_config")"
  proxy_cmd="$(awk '$1=="proxycommand" {print $2; exit}' <<<"$ssh_config")"
  if [[ -n "$proxy_jump" && "$proxy_jump" != "none" ]]; then
    printf '%s' "$base_host"
    return
  fi
  if [[ -n "$proxy_cmd" && "$proxy_cmd" != "none" ]]; then
    printf '%s' "$base_host"
    return
  fi

  resolved="$(dig +short +time=1 +tries=1 "@${LAN_DNS_SERVER}" "$base_host" A | head -n1)"
  if [[ -n "$resolved" ]]; then
    SSH_HOST_OPTS=(-o HostName="$resolved" -o HostKeyAlias="$base_host")
    printf '%s' "$base_host"
    return
  fi

  printf '%s' "$base_host"
}

ssh_base_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=8
)

avail_gb_local() {
  local path="$1"
  df -Pk "$path" | awk 'NR==2 {printf "%.1f", $4/1024/1024}'
}

avail_gb_remote_cmd() {
  local path_literal="$1"
  printf '%s\n' "df -Pk \"$path_literal\" | awk 'NR==2 {printf \"%.1f\", \\$4/1024/1024}'"
}

print_lines_if_any() {
  local -a lines=("$@")
  if [[ ${#lines[@]} -gt 0 ]]; then
    printf '%b\n' "${lines[@]}"
  fi
}

is_local_host() {
  local host="$1"
  local local_short local_full
  local_short="$(hostname -s 2>/dev/null || hostname)"
  local_full="$(hostname -f 2>/dev/null || hostname)"
  [[ "$host" == "localhost" || "$host" == "$local_short" || "$host" == "$local_full" ]]
}

run_selector() {
  local -a items=("$@")
  local tmpfile selection
  if [[ ${#items[@]} -eq 0 ]]; then
    echo "No items to select." >&2
    exit 1
  fi
  tmpfile="$(mktemp)"
  printf '%s\n' "${items[@]}" >"$tmpfile"
  if ! selection="$(python3 "${REPO_ROOT}/scripts/_helpers/selector.py" --file "$tmpfile")"; then
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
  printf '%s\n' "$summary_text" | python3 "${REPO_ROOT}/scripts/_helpers/box.py" \
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

get_local_avail_path() {
  if [[ -d /nix/store ]]; then
    printf '%s' "/nix/store"
  elif [[ -d /nix ]]; then
    printf '%s' "/nix"
  else
    printf '%s' "$HOME"
  fi
}

local_disk_cleanup_if_low() {
  local avail_path avail_kb avail_gb
  avail_path="$(get_local_avail_path)"
  avail_kb="$(df -Pk "$avail_path" | awk 'NR==2 {print $4}')"
  if [[ -z "$avail_kb" ]]; then
    return 0
  fi
  avail_gb="$(awk "BEGIN {printf \"%.1f\", ${avail_kb}/1024/1024}")"
  printf '%b\n' "${COLOR_DIM}Local available disk on ${avail_path}: ${avail_gb} GiB${COLOR_RESET}"
  if [[ "$avail_kb" -lt "$MIN_DISK_KB" ]]; then
    echo "Low local disk space (<${MIN_DISK_GIB}GiB). Running nix-collect-garbage -d..."
    sudo nix-collect-garbage -d
  fi
}

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

local_disk_cleanup_if_low

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
  mapfile -t HOSTS < <(hosts_from_work_map "$WORK_MAP")
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

# Only apply mode filtering when discovering hosts (ALL=true).
# When hosts are explicitly passed, update them without filtering.
if [[ "$ALL" == "true" && "$MODE" != "both" ]]; then
  mapfile -t filtered < <(filter_hosts_by_mode "$MODE" "$WORK_MAP" "${HOSTS[@]}")
  HOSTS=("${filtered[@]}")
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "No hosts selected after applying mode '$MODE'." >&2
  exit 1
fi

if [[ "$SELECT" == "true" ]]; then
  if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "No hosts available for selection." >&2
    exit 1
  fi
  mapfile -t sorted_hosts < <(printf '%s\n' "${HOSTS[@]}" | LC_ALL=C sort)
  selection="$(run_selector "${sorted_hosts[@]}")"
  if [[ -z "$selection" ]]; then
    echo "No selection made." >&2
    exit 1
  fi
  mapfile -t selected <<<"$selection"
  HOSTS=("${selected[@]}")
fi

mapfile -t HOSTS < <(prioritize_hosts "${HOSTS[@]}")

echo "Checking SSH connectivity to ${#HOSTS[@]} hosts..."
failed=0
host_status_lines=()
for host in "${HOSTS[@]}"; do
  ssh_host="$(resolve_ssh_host "$host")"
  if is_local_host "$host"; then
    ok="ok (local)"
  else
    if ssh "${ssh_base_opts[@]}" "${SSH_OPTS_ARR[@]}" "${SSH_HOST_OPTS[@]}" "$ssh_host" true >/dev/null 2>&1; then
      ok="ok"
    else
      ok="failed"
      failed=$((failed + 1))
    fi
  fi

  avail_gb=""
  if [[ "$DRY_RUN" == "true" && "$ok" == ok* ]]; then
    if is_local_host "$host"; then
      avail_path="$(get_local_avail_path)"
      avail_gb="$(avail_gb_local "$avail_path" 2>/dev/null || true)"
    else
      # shellcheck disable=SC2029
      avail_gb="$(ssh "${ssh_base_opts[@]}" "${SSH_OPTS_ARR[@]}" "${SSH_HOST_OPTS[@]}" "$ssh_host" "$(avail_gb_remote_cmd "\\\$HOME")" 2>/dev/null || true)"
    fi
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

print_lines_if_any "${host_status_lines[@]}"

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
  remote_payload="$(cat <<'REMOTE'
set -euo pipefail
trap 'rm -f "$0"' EXIT
MIN_DISK_KB="$1"
MIN_DISK_GIB="$2"
branch="$3"
repo_url="$4"
repo_dir="$(mktemp -d)"
trap 'rm -rf "$repo_dir"' EXIT

get_avail_path() {
  if [[ -d /nix/store ]]; then
    printf '%s' "/nix/store"
  elif [[ -d /nix ]]; then
    printf '%s' "/nix"
  else
    printf '%s' "$HOME"
  fi
}

set_avail_gib() {
  AVAIL_PATH="$(get_avail_path)"
  AVAIL_KB="$(df -Pk "$AVAIL_PATH" | awk 'NR==2 {print $4}')"
  if [[ -z "$AVAIL_KB" ]]; then
    return 1
  fi
  AVAIL_GB="$(awk "BEGIN {printf \"%.1f\", ${AVAIL_KB}/1024/1024}")"
}

AVAIL_KB=""
AVAIL_GB=""
AVAIL_PATH=""
if set_avail_gib; then
  printf '\033[1;33m%s\033[0m\n' "Available disk on ${AVAIL_PATH}: ${AVAIL_GB} GiB"
fi
if [[ -n "$AVAIL_KB" && "$AVAIL_KB" -lt "$MIN_DISK_KB" ]]; then
  echo "Low disk space (<${MIN_DISK_GIB}GiB). Running nix-collect-garbage -d..."
  sudo nix-collect-garbage -d
  if set_avail_gib; then
    printf '\033[1;33m%s\033[0m\n' "Available disk after cleanup on ${AVAIL_PATH}: ${AVAIL_GB} GiB"
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
)"
  if is_local_host "$host"; then
    printf '%s\n' "$remote_payload" > "$remote_script"
    chmod +x "$remote_script"
    if "$remote_script" "$MIN_DISK_KB" "$MIN_DISK_GIB" "$BRANCH" "$REPO_URL"; then
      ok_hosts+=("$host")
    else
      failed_hosts+=("$host")
    fi
    continue
  fi
  # shellcheck disable=SC2029
  printf '%s\n' "$remote_payload" | ssh "${SSH_OPTS_ARR[@]}" "${SSH_HOST_OPTS[@]}" "$ssh_host" "cat > \"$remote_script\" && chmod +x \"$remote_script\""
  if ssh -tt "${SSH_OPTS_ARR[@]}" "${SSH_HOST_OPTS[@]}" "$ssh_host" "$remote_script" "$MIN_DISK_KB" "$MIN_DISK_GIB" "$BRANCH" "$REPO_URL"; then
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
