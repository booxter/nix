# Copied from https://github.com/reckenrode/nixos-configs/blob/main/modules/by-name/co/copy-apps/module.nix
# Then also from: https://github.com/nix-darwin/nix-darwin/pull/1396
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}:

let
  appsSrc =
    if config ? home then
      "$newGenPath/home-path/Applications"
    else
      config.system.build.applications + /Applications;

  baseDir =
    if config ? home then
      "${config.home.homeDirectory}/Applications/Home Manager Apps"
    else
      "/Applications/Nix Apps";

  copyScript =
    lib.optionalString (config ? system) ''
      echo 'Setting up /Applications/Nix Apps...' >&2
    ''
    + ''
      appsSrc="${appsSrc}"
      if [ -d "$appsSrc" ]; then
        baseDir="${baseDir}"
        rsyncFlags=(
          --checksum
          --copy-unsafe-links
          --archive
          --delete
          --chmod=-w
          --no-group
          --no-owner
        )
        $DRY_RUN_CMD mkdir -p "$baseDir"
        $DRY_RUN_CMD ${lib.getBin pkgs.rsync}/bin/rsync \
          ''${VERBOSE_ARG:+-v} "''${rsyncFlags[@]}" "$appsSrc/" "$baseDir"
      fi
    '';

  isHomeManager = lib.hasAttr "hm" lib;
in
{
  disabledModules = [ "targets/darwin/linkapps.nix" ];

  config = lib.mkIf pkgs.stdenv.isDarwin (
    lib.optionalAttrs isHomeManager {
      home.activation.copyApplications = lib.hm.dag.entryAfter [ "writeBoundary" ] copyScript;
    }
    // lib.optionalAttrs (!isHomeManager) {
      system.activationScripts.applications.text = lib.mkForce copyScript;
    }
  );
}
