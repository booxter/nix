#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/nix-target-diff.sh [--base <git-ref>] <host>

Diff systemd service configs for a NixOS host between the base ref and the
current working tree.

Examples:
  scripts/nix-target-diff.sh frame
  scripts/nix-target-diff.sh --base origin/master frame
EOF
}

base_ref=""
attr=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--base)
			base_ref="${2:-}"
			shift 2
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
			attr="$1"
			shift
			break
			;;
	esac
done

if [[ -z "${attr}" ]]; then
	usage >&2
	exit 1
fi

attr="${attr#\#}"
attr="${attr#\.#}"
attr="${attr#.}"

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

if [[ -z "${base_ref}" ]]; then
	for candidate in origin/master origin/main master main; do
		if git rev-parse --verify --quiet "${candidate}" >/dev/null; then
			base_ref="${candidate}"
			break
		fi
	done
fi

if [[ -z "${base_ref}" ]]; then
	echo "Unable to determine base ref; pass --base <git-ref>." >&2
	exit 1
fi

base_rev="$(git rev-parse "${base_ref}")"
current_rev="$(git rev-parse HEAD)"

flake_base="git+file://${repo_root}?rev=${base_rev}"
flake_current="path:${repo_root}"

nix_opts=(--extra-experimental-features "nix-command flakes")
if [[ -n "${NIX_EVAL_OPTS:-}" ]]; then
	read -r -a extra_opts <<<"${NIX_EVAL_OPTS}"
	nix_opts+=("${extra_opts[@]}")
fi

if [[ "${attr}" == nixosConfigurations.* ]]; then
	rest="${attr#nixosConfigurations.}"
	host="${rest%%.*}"
else
	host="${attr}"
fi

config_attr="nixosConfigurations.${host}.config.systemd.services"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

format_json() {
	if command -v jq >/dev/null 2>&1; then
		jq -S
	else
		python -m json.tool
	fi
}

nix_eval_json() {
	local flake="$1"
	local attr="$2"
	local apply_expr="$3"

	nix eval "${nix_opts[@]}" --json "${flake}#${attr}" --apply "${apply_expr}" \
		2> >(grep -v '^evaluation warning:' >&2)
}

eval_services() {
	local flake="$1"
	local config="$2"
	local apply_expr=""

	apply_expr="$(cat <<'NIX'
svcs:
let
  postProcess =
    s:
    let
      unitConfig = builtins.removeAttrs (s.unitConfig or { }) [ "X-Restart-Triggers" ];
    in
    {
      enable = s.enable or null;
      wantedBy = s.wantedBy or [ ];
      requiredBy = s.requiredBy or [ ];
      after = s.after or [ ];
      before = s.before or [ ];
      aliases = s.aliases or [ ];
      unitConfig = unitConfig;
      serviceConfig = s.serviceConfig or { };
    };
in
builtins.mapAttrs (_: s: postProcess s) svcs
NIX
)"

	nix_eval_json "${flake}" "${config}" "${apply_expr}"
}

echo "Base ref: ${base_ref} (${base_rev})"
echo "Current : HEAD (${current_rev})"
echo "Host    : ${host}"
echo "Attr    : ${config_attr}"

eval_services "${flake_base}" "${config_attr}" | format_json >"${tmpdir}/base.json"
eval_services "${flake_current}" "${config_attr}" | format_json >"${tmpdir}/current.json"

diff -u "${tmpdir}/base.json" "${tmpdir}/current.json" || true
