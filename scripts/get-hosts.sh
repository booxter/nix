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
    hostInventory = import \"${REPO_ROOT}/lib/hosts.nix\" {
      # get-hosts only needs VM naming and isWork flags. Keep this import cheap
      # by stubbing the one lib function hosts.nix currently references for the
      # unrelated UPS-name helper.
      lib = {
        strings.toUpper = s: s;
      };
    };
    toVmName = hostInventory.toVmName;
    hostWorkMap = {
      darwin = builtins.mapAttrs (_: cfg: cfg.isWork or false) hostInventory.darwinHosts;
      nixos = builtins.foldl' (
        acc: spec:
        let
          isWork = spec.isWork or false;
        in
        if spec.type == \"bm\" then
          acc
          // {
            \${spec.name} = isWork;
            \${\"local-\${spec.name}vm\"} = isWork;
          }
        else if spec.type == \"vm\" then
          acc
          // {
            \${\"local-\${toVmName spec.name}\"} = isWork;
            \${\"prox-\${toVmName spec.name}\"} = isWork;
          }
        else
          throw \"Unsupported NixOS host spec type \${spec.type}\"
      ) { } hostInventory.nixosHostSpecs;
    };
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
