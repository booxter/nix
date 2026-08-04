"""Remote Bash payloads retained from the hardware-tested workflow.

These operations deliberately remain shell scripts: they are transactional
Linux host procedures involving sudo, pipelines, conditional device state,
and a sas3flash command array. The local controller sends them as data through
OpenSSH and never interpolates operator input into their source.
"""

PREFLIGHT = r"""set -euo pipefail

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
"""

CHECK_TOOL = r"""set -euo pipefail

remote_dir="$1"
controller="$2"
tool="${remote_dir}/sas3flash"

chmod 0755 "${tool}"

echo "=== sas3flash -listall ==="
sudo "${tool}" -listall

echo "=== sas3flash -c ${controller} -list ==="
sudo "${tool}" -c "${controller}" -list
"""

QUIESCE = r"""set -euo pipefail

sudo systemctl stop jellyfin nfs-server nfs-mountd nfs-idmapd nfsdcld || true
sudo umount /media 2>/dev/null || true
sudo umount /volume2/Media 2>/dev/null || true
sudo umount /volume2 2>/dev/null || true
if [[ -e /dev/md127 ]]; then
  sudo mdadm --stop /dev/md127 2>/dev/null || true
fi
"""

VERIFY_QUIESCED = r"""set -euo pipefail

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
"""

FLASH = r"""set -euo pipefail

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
"""
