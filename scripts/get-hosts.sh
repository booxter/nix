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
    f = builtins.getFlake \"${REPO_ROOT}\";
    requestedHosts = ${HOSTS_NIX};
    toWork = cfg: cfg.config.host.isWork or false;
    filterNames = attrs: requestedList:
      let
        allNames = builtins.attrNames attrs;
        filteredAll = builtins.filter
          (name:
            (builtins.match \"^(local-|ci-).*\" name) == null
            && (builtins.match \".*-ci\$\" name) == null
          )
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
    nixos = builtins.mapAttrs (_: toWork) (filterNames f.nixosConfigurations requestedHosts);
    darwin = builtins.mapAttrs (_: toWork) (filterNames f.darwinConfigurations requestedHosts);
  }
"
