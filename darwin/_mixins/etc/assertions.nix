{ config, lib, ... }:
let
  inherit (import ./lib.nix { inherit lib; }) validTarget;
  enabledEtc = lib.filterAttrs (_: entry: entry.enable) config.environment.etc;
  copiedEntries = builtins.attrValues (
    lib.filterAttrs (_: entry: entry.mode != "symlink") enabledEtc
  );
in
{
  assertions = map (entry: {
    assertion = validTarget entry.target;
    message = "Copied environment.etc target '${entry.target}' must be a safe path relative to /etc.";
  }) copiedEntries;
}
