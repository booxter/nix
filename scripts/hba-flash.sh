#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

host="beast"
controller="0"
bundle=""
sas3flash_bundle=""
firmware_bundle=""
sas3flash=""
firmware=""
optionrom=""
flash_mode=0
quiesce_mode=1
reboot_after=0
keep_remote=0
remote_dir=""
local_tmpdirs=()

note() {
  printf '[hba-flash] %s\n' "$*" >&2
}

die() {
  note "error: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  hba-flash [--host beast] [--controller 0]
            [--bundle DIR|ZIP]
            [--sas3flash-bundle DIR|ZIP] [--firmware-bundle DIR|ZIP]
            [--sas3flash FILE] [--firmware FILE] [--optionrom FILE]
  hba-flash --flash [same options as above]

Default behavior is preflight-only: inspect the remote host, stage the Broadcom utility,
and run read-only controller inventory commands. Use --flash to actually quiesce the
host and update the controller firmware.

Inputs:
  --bundle PATH        Broadcom bundle directory or ZIP to search for both sas3flash and firmware.
  --sas3flash-bundle PATH
                       Broadcom utility bundle directory or ZIP to search only for the Linux sas3flash binary.
  --firmware-bundle PATH
                       Broadcom firmware bundle directory or ZIP to search only for the HBA firmware image.
  --sas3flash FILE     Path to the sas3flash Linux utility.
  --firmware FILE      Path to the HBA firmware image.
  --optionrom FILE     Optional BIOS/UEFI option ROM image to flash with -b.

Execution:
  --host HOST          SSH target. Default: beast
  --controller N       sas3flash controller index. Default: 0
  --flash              Perform the firmware flash instead of only preflight checks.
  --no-quiesce         Skip remote service stop / unmount / md stop before flashing.
  --reboot             Reboot the host after a successful flash.
  --keep-remote        Keep the staged /tmp/hba-flash-* directory on the remote host.
  -h, --help           Show this help.

Examples:
  nix run .#hba-flash --
  nix run .#hba-flash -- --flash
  nix run .#hba-flash -- --bundle ~/Downloads/SAS9305_PKG
  nix run .#hba-flash -- --flash --bundle ~/Downloads/SAS9305_PKG.zip
  nix run .#hba-flash -- --sas3flash-bundle ~/Downloads/SAS3FLASH_P15.zip \
    --firmware-bundle ~/Downloads/9305_24i_Pkg_P16.12_IT_FW_BIOS_for_MSDOS_Windows.zip
  nix run .#hba-flash -- --flash --sas3flash ~/Downloads/sas3flash --firmware ~/Downloads/9305-24i.bin

Notes:
  - Broadcom does not expose this HBA firmware through fwupd on beast.
  - If the app was built with pinned Broadcom bundles, it will use those by default.
  - Otherwise, pass the official Broadcom sas3flash utility and firmware image(s)
    explicitly, typically downloaded from the Broadcom Support portal.
EOF
}

cleanup_remote() {
  if [[ -n "${remote_dir}" && "${keep_remote}" -eq 0 ]]; then
    # shellcheck disable=SC2029
    ssh "${host}" "rm -rf '${remote_dir}'" >/dev/null 2>&1 || true
  fi
}

cleanup_local() {
  local path
  for path in "${local_tmpdirs[@]:-}"; do
    [[ -n "${path}" ]] || continue
    rm -rf "${path}" >/dev/null 2>&1 || true
  done
}

cleanup_all() {
  cleanup_remote
  cleanup_local
}

trap cleanup_all EXIT

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || die "file not found: ${path}"
}

abs_path() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s/%s\n' "${PWD}" "${path}"
  fi
}

prepare_bundle_path() {
  local label="$1"
  local path="$2"
  local abs
  local tmpdir

  abs="$(abs_path "${path}")"
  if [[ -d "${abs}" ]]; then
    printf '%s\n' "${abs}"
    return
  fi

  if [[ -f "${abs}" ]]; then
    case "${abs}" in
      *.zip | *.ZIP)
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/hba-flash-${label}.XXXXXX")"
        note "extracting ${label} ZIP: ${abs}"
        unzip -q "${abs}" -d "${tmpdir}"
        local_tmpdirs+=("${tmpdir}")
        printf '%s\n' "${tmpdir}"
        return
        ;;
    esac
  fi

  die "${label} must be a directory or ZIP file: ${path}"
}

append_unique() {
  local candidate="$1"
  local existing
  for existing in "${_hits[@]:-}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  _hits+=("${candidate}")
}

find_candidates() {
  local root="$1"
  shift
  local pattern

  _hits=()
  while (($#)); do
    pattern="$1"
    shift
    while IFS= read -r candidate; do
      append_unique "${candidate}"
    done < <(find "${root}" -type f -iname "${pattern}" -print 2>/dev/null | sort)
  done

  printf '%s\n' "${_hits[@]:-}"
}

choose_one() {
  local label="$1"
  shift
  local -a values=("$@")

  case "${#values[@]}" in
    0)
      return 1
      ;;
    1)
      printf '%s\n' "${values[0]}"
      ;;
    *)
      note "multiple ${label} candidates found:"
      printf '  %s\n' "${values[@]}" >&2
      die "please pass --${label} explicitly"
      ;;
  esac
}

collect_bundle_roots() {
  local kind="$1"

  case "${kind}" in
    sas3flash)
      [[ -n "${sas3flash_bundle}" ]] && printf '%s\n' "${sas3flash_bundle}"
      [[ -n "${bundle}" ]] && printf '%s\n' "${bundle}"
      ;;
    firmware)
      [[ -n "${firmware_bundle}" ]] && printf '%s\n' "${firmware_bundle}"
      [[ -n "${bundle}" ]] && printf '%s\n' "${bundle}"
      ;;
    *)
      die "unknown bundle kind: ${kind}"
      ;;
  esac
}

resolve_sas3flash() {
  local -a roots=()
  local -a preferred_candidates=()
  local -a candidates=()
  local candidate
  local root

  if [[ -n "${sas3flash}" ]]; then
    require_file "${sas3flash}"
    sas3flash="$(abs_path "${sas3flash}")"
    return
  fi

  while IFS= read -r root; do
    [[ -n "${root}" ]] || continue
    roots+=("${root}")
  done < <(collect_bundle_roots sas3flash)

  ((${#roots[@]} > 0)) || die "pass --bundle, --sas3flash-bundle, or --sas3flash explicitly"

  _hits=()
  for root in "${roots[@]}"; do
    while IFS= read -r candidate; do
      [[ -n "${candidate}" ]] || continue
      append_unique "${candidate}"
    done < <(find "${root}" -type f \
      \( -path '*/sas3flash_linux_x64_rel/sas3flash' -o -path '*/sas3flash_linux_amd64_rel/sas3flash' \) \
      -print 2>/dev/null | sort)
  done
  preferred_candidates=("${_hits[@]:-}")

  if ((${#preferred_candidates[@]} > 0)); then
    sas3flash="$(choose_one sas3flash "${preferred_candidates[@]}")"
    sas3flash="$(abs_path "${sas3flash}")"
    return
  fi

  for root in "${roots[@]}"; do
    while IFS= read -r candidate; do
      [[ -n "${candidate}" ]] || continue
      candidates+=("${candidate}")
    done < <(find_candidates "${root}" 'sas3flash' 'sas3flash*' 'sas3flsh*')
  done

  if ((${#candidates[@]} > 0)); then
    note "found sas3flash candidates, but no Linux x64 binary:"
    printf '  %s\n' "${candidates[@]}" >&2
    die "pass --sas3flash explicitly or provide a Linux sas3flash bundle"
  fi

  die "no sas3flash binary found in the provided bundle(s)"
}

resolve_firmware() {
  local -a roots=()
  local -a direct_candidates=()
  local -a fallback_candidates=()
  local candidate
  local base
  local root

  if [[ -n "${firmware}" ]]; then
    require_file "${firmware}"
    firmware="$(abs_path "${firmware}")"
    return
  fi

  while IFS= read -r root; do
    [[ -n "${root}" ]] || continue
    roots+=("${root}")
  done < <(collect_bundle_roots firmware)

  ((${#roots[@]} > 0)) || die "pass --bundle, --firmware-bundle, or --firmware explicitly"

  for root in "${roots[@]}"; do
    while IFS= read -r candidate; do
      [[ -n "${candidate}" ]] || continue
      direct_candidates+=("${candidate}")
    done < <(find_candidates "${root}" '*9305*24i*IT*.bin' '*9305*24i*.bin' '*9305*.bin' '*3224*.bin')
  done

  if ((${#direct_candidates[@]} == 1)); then
    firmware="$(abs_path "${direct_candidates[0]}")"
    return
  fi

  for root in "${roots[@]}"; do
    while IFS= read -r candidate; do
      [[ -n "${candidate}" ]] || continue
      base="$(basename "${candidate}")"
      case "${base}" in
        *.rom | *.ROM | mptsas3* | MPTSAS3*)
          continue
          ;;
      esac
      fallback_candidates+=("${candidate}")
    done < <(find_candidates "${root}" '*.bin' '*.fw')
  done

  firmware="$(choose_one firmware "${direct_candidates[@]}" "${fallback_candidates[@]}")"
  firmware="$(abs_path "${firmware}")"
}

resolve_optionrom() {
  if [[ -z "${optionrom}" ]]; then
    return
  fi

  require_file "${optionrom}"
  optionrom="$(abs_path "${optionrom}")"
}

remote_bash() {
  ssh "${host}" bash -s -- "$@"
}

preflight_remote() {
  note "remote preflight on ${host}"
  remote_bash "${controller}" <<'EOF'
set -euo pipefail

controller="$1"

echo "=== host ==="
hostname
date

echo "=== lspci ==="
lspci -nn | egrep -i 'Serial Attached SCSI|SAS3224|Broadcom|LSI' || true

echo "=== md ==="
cat /proc/mdstat || true
if [[ -e /dev/md127 ]]; then
  echo "--- /dev/md127 ---"
  sudo mdadm --detail /dev/md127 || true
fi

echo "=== mounts ==="
findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS /volume2 /media 2>/dev/null || true

echo "=== services ==="
systemctl is-active jellyfin nfs-server nfs-mountd nfs-idmapd nfsdcld 2>/dev/null || true

echo "=== controller-index ==="
printf 'controller=%s\n' "${controller}"
EOF
}

stage_remote() {
  local firmware_target optionrom_target

  remote_dir="/tmp/hba-flash-$(date +%Y%m%d-%H%M%S)-$$"
  firmware_target="${remote_dir}/firmware.bin"
  optionrom_target="${remote_dir}/optionrom.rom"

  note "staging utility and firmware in ${remote_dir} on ${host}"
  # shellcheck disable=SC2029
  ssh "${host}" "mkdir -p '${remote_dir}'"
  scp -q "${sas3flash}" "${host}:${remote_dir}/sas3flash"
  scp -q "${firmware}" "${host}:${firmware_target}"
  if [[ -n "${optionrom}" ]]; then
    scp -q "${optionrom}" "${host}:${optionrom_target}"
  fi
}

check_remote_tool() {
  note "checking staged sas3flash utility"
  remote_bash "${remote_dir}" "${controller}" <<'EOF'
set -euo pipefail

remote_dir="$1"
controller="$2"
tool="${remote_dir}/sas3flash"

chmod 0755 "${tool}"

echo "=== sas3flash -listall ==="
sudo "${tool}" -listall

echo "=== sas3flash -c ${controller} -list ==="
sudo "${tool}" -c "${controller}" -list
EOF
}

quiesce_remote() {
  note "stopping media and NFS services on ${host}"
  remote_bash <<'EOF'
set -euo pipefail

sudo systemctl stop jellyfin nfs-server nfs-mountd nfs-idmapd nfsdcld || true
sudo umount /media 2>/dev/null || true
sudo umount /volume2/Media 2>/dev/null || true
sudo umount /volume2 2>/dev/null || true
if [[ -e /dev/md127 ]]; then
  sudo mdadm --stop /dev/md127 2>/dev/null || true
fi
EOF
}

verify_quiesced_remote() {
  note "verifying ${host} is quiesced before flash"
  remote_bash <<'EOF'
set -euo pipefail

if findmnt -rn -S /dev/md127 >/dev/null 2>&1; then
  echo "md127 is still mounted" >&2
  exit 1
fi

if grep -q '^md127 : ' /proc/mdstat 2>/dev/null; then
  echo "md127 is still active in /proc/mdstat" >&2
  exit 1
fi

systemctl is-active jellyfin nfs-server nfs-mountd nfs-idmapd nfsdcld 2>/dev/null \
  | grep -q '^active$' && {
    echo "one or more storage-touching services are still active" >&2
    exit 1
  } || true
EOF
}

flash_remote() {
  note "flashing controller ${controller} on ${host}"
  remote_bash "${remote_dir}" "${controller}" "$([[ -n "${optionrom}" ]] && echo 1 || echo 0)" <<'EOF'
set -euo pipefail

remote_dir="$1"
controller="$2"
with_optionrom="$3"
tool="${remote_dir}/sas3flash"
firmware="${remote_dir}/firmware.bin"
optionrom="${remote_dir}/optionrom.rom"

echo "=== pre-flash listall ==="
sudo "${tool}" -listall

echo "=== pre-flash controller detail ==="
sudo "${tool}" -c "${controller}" -list

cmd=(sudo "${tool}" -c "${controller}" -o -f "${firmware}")
if [[ "${with_optionrom}" == 1 ]]; then
  cmd+=(-b "${optionrom}")
fi

echo "=== flash command ==="
printf '%q ' "${cmd[@]}"
echo

"${cmd[@]}"

echo "=== post-flash controller detail ==="
sudo "${tool}" -c "${controller}" -list
EOF
}

reboot_remote() {
  note "rebooting ${host}"
  ssh "${host}" 'sudo systemctl reboot'
}

while (($#)); do
  case "$1" in
    --host)
      host="${2:?missing value for --host}"
      shift 2
      ;;
    --controller)
      controller="${2:?missing value for --controller}"
      shift 2
      ;;
    --bundle)
      bundle="${2:?missing value for --bundle}"
      shift 2
      ;;
    --sas3flash-bundle)
      sas3flash_bundle="${2:?missing value for --sas3flash-bundle}"
      shift 2
      ;;
    --firmware-bundle)
      firmware_bundle="${2:?missing value for --firmware-bundle}"
      shift 2
      ;;
    --sas3flash)
      sas3flash="${2:?missing value for --sas3flash}"
      shift 2
      ;;
    --firmware)
      firmware="${2:?missing value for --firmware}"
      shift 2
      ;;
    --optionrom)
      optionrom="${2:?missing value for --optionrom}"
      shift 2
      ;;
    --flash)
      flash_mode=1
      shift
      ;;
    --no-quiesce)
      quiesce_mode=0
      shift
      ;;
    --reboot)
      reboot_after=1
      shift
      ;;
    --keep-remote)
      keep_remote=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -n "${bundle}" ]]; then
  bundle="$(prepare_bundle_path bundle "${bundle}")"
fi

if [[ -n "${sas3flash_bundle}" ]]; then
  sas3flash_bundle="$(prepare_bundle_path sas3flash-bundle "${sas3flash_bundle}")"
fi

if [[ -n "${firmware_bundle}" ]]; then
  firmware_bundle="$(prepare_bundle_path firmware-bundle "${firmware_bundle}")"
fi

if [[ -z "${bundle}" && -z "${sas3flash_bundle}" && -z "${sas3flash}" && -n "${HBA_FLASH_DEFAULT_SAS3FLASH_BUNDLE:-}" ]]; then
  sas3flash_bundle="${HBA_FLASH_DEFAULT_SAS3FLASH_BUNDLE}"
  note "using default sas3flash bundle: ${sas3flash_bundle}"
fi

if [[ -z "${bundle}" && -z "${firmware_bundle}" && -z "${firmware}" && -n "${HBA_FLASH_DEFAULT_FIRMWARE_BUNDLE:-}" ]]; then
  firmware_bundle="${HBA_FLASH_DEFAULT_FIRMWARE_BUNDLE}"
  note "using default firmware bundle: ${firmware_bundle}"
fi

resolve_sas3flash
resolve_firmware
resolve_optionrom

note "local sas3flash: ${sas3flash}"
note "local firmware: ${firmware}"
if [[ -n "${optionrom}" ]]; then
  note "local optionrom: ${optionrom}"
fi

preflight_remote
stage_remote
check_remote_tool

if [[ "${flash_mode}" -eq 0 ]]; then
  note "preflight finished; rerun with --flash to update firmware"
  exit 0
fi

if [[ "${quiesce_mode}" -eq 1 ]]; then
  quiesce_remote
  verify_quiesced_remote
fi

flash_remote

if [[ "${reboot_after}" -eq 1 ]]; then
  reboot_remote
else
  note "flash completed; reboot ${host} before using the controller"
fi
