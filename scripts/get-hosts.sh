#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Convert arguments to a Nix list string, e.g. '[ "host1" "host2" ]'
# If no arguments, use null to indicate "all hosts"
if [[ $# -gt 0 ]]; then
  HOSTS_NIX="[ $(printf '"%s" ' "$@")]"
else
  HOSTS_NIX="null"
fi

nix eval --impure --json --expr "
  let
    hostWorkMap = import \"${REPO_ROOT}/lib/host-work-map.nix\" {};
    requestedHosts = ${HOSTS_NIX};
    filterNames = attrs: requestedList:
      let
        allNames = builtins.attrNames attrs;
        filteredAll = builtins.filter
          (name: (builtins.match \"^local-.*\" name) == null)
          allNames;
        namesToUse =
          if requestedList == null
          then filteredAll
          else builtins.filter (name: builtins.elem name allNames) requestedList;
      in
      builtins.listToAttrs (
        map
          (name: {
            inherit name;
            value = builtins.getAttr name attrs;
          })
          namesToUse
      );
  in
  {
    nixos = filterNames hostWorkMap.nixos requestedHosts;
    darwin = filterNames hostWorkMap.darwin requestedHosts;
  }
"
