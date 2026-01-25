#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

nix eval --impure --json --expr "
  let
    f = builtins.getFlake \"${REPO_ROOT}\";
    toWork = cfg: cfg.config.host.isWork or false;
    filterNames = attrs:
      builtins.listToAttrs (
        map
          (name: {
            inherit name;
            value = builtins.getAttr name attrs;
          })
          (builtins.filter
            (name:
              (builtins.match \"^(local-|ci-).*\" name) == null
              && (builtins.match \".*-ci$\" name) == null
            )
            (builtins.attrNames attrs))
      );
  in
  {
    nixos = builtins.mapAttrs (_: toWork) (filterNames f.nixosConfigurations);
    darwin = builtins.mapAttrs (_: toWork) (filterNames f.darwinConfigurations);
  }
"
