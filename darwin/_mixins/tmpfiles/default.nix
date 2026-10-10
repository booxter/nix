{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ./lib.nix { inherit lib pkgs; })
    validPath
    directoryFunction
    directoryCommand
    ;
  cfg = config.system.tmpfiles;
  ruleType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        type = lib.mkOption {
          type = lib.types.enum [ "d" ];
          default = name;
          description = "Only the tmpfiles directory operation (d) is supported on Darwin.";
        };
        mode = lib.mkOption {
          type = lib.types.strMatching "[0-7]{4}";
          description = "Explicit directory mode. Tmpfiles mode modifiers are not supported.";
        };
        user = lib.mkOption {
          type = lib.types.strMatching "[a-zA-Z0-9_][a-zA-Z0-9_-]*";
          description = "Explicit directory owner name or numeric UID.";
        };
        group = lib.mkOption {
          type = lib.types.strMatching "[a-zA-Z0-9_][a-zA-Z0-9_-]*";
          description = "Explicit directory group name or numeric GID.";
        };
        age = lib.mkOption {
          type = lib.types.enum [ "-" ];
          default = "-";
          description = "Cleanup is not supported.";
        };
        argument = lib.mkOption {
          type = lib.types.enum [ "" ];
          default = "";
          description = "Directory rules do not accept an argument.";
        };
      };
    }
  );
  # Merge by path across named groups so conflicting declarations fail evaluation.
  groupedPaths = lib.zipAttrs (builtins.attrValues cfg.settings);
  directories = lib.mapAttrs (
    path: declarations:
    let
      rules = lib.concatMap builtins.attrValues declarations;
      uniqueRules = lib.unique rules;
    in
    if !validPath path then
      throw "system.tmpfiles: expected a literal absolute directory path, got '${path}'"
    else if builtins.any (declaration: builtins.attrNames declaration != [ "d" ]) declarations then
      throw "system.tmpfiles: only the d operation is supported for '${path}'"
    else if builtins.length uniqueRules != 1 then
      throw "system.tmpfiles: conflicting directory rules for '${path}'"
    else
      builtins.deepSeq uniqueRules (builtins.head uniqueRules)
  ) groupedPaths;
in
{
  options.system.tmpfiles.settings = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf (lib.types.attrsOf ruleType));
    default = { };
    description = ''
      A subset of NixOS systemd.tmpfiles.settings for persistent Darwin directories.
      Only literal paths and d rules with explicit mode, user and group are supported.
      Directories are prepared during activation; contents are preserved and removing
      a rule does not delete its directory. This does not provide boot-time ordering.
    '';
    example.ups."/var/lib/nut".d = {
      mode = "0700";
      user = "root";
      group = "wheel";
    };
  };

  # Accounts must exist, and directories must precede applications, /etc and launchd.
  config.system.activationScripts.users.text = lib.mkAfter (
    lib.optionalString (directories != { }) ''
      ${directoryFunction}
      ${lib.concatStrings (lib.mapAttrsToList directoryCommand directories)}
      unset -f darwinTmpfilesDirectory
    ''
  );
}
