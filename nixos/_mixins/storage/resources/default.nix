{ lib, ... }:
let
  directoryModule = {
    options = {
      owner = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Directory owner, or null to inherit the resource default.";
      };
      group = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Directory group, or null to inherit the resource default.";
      };
      mode = lib.mkOption {
        type = with lib.types; nullOr (strMatching "[0-7]{4}");
        default = null;
        description = "Directory mode, or null to inherit the resource default.";
      };
      enforce = lib.mkOption {
        type = with lib.types; nullOr bool;
        default = null;
        description = "Whether tmpfiles enforces ownership and mode on existing paths.";
      };
    };
  };
in
{
  imports = [
    ./assertions.nix
    ./config.nix
  ];

  options.host.storage = {
    resources = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              volume = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Host storage volume containing the ${name} resource.";
              };
              relativePath = lib.mkOption {
                type = lib.types.nonEmptyStr;
                default = name;
                description = "Resource path relative to its volume mount point.";
              };
              sharedGroup = lib.mkOption {
                type = with lib.types; nullOr nonEmptyStr;
                default = null;
                description = "Shared numeric group required on providers and consumers.";
              };
              directoryDefaults = {
                owner = lib.mkOption {
                  type = lib.types.nonEmptyStr;
                  default = "root";
                };
                group = lib.mkOption {
                  type = lib.types.nonEmptyStr;
                  default = "root";
                };
                mode = lib.mkOption {
                  type = lib.types.strMatching "[0-7]{4}";
                  default = "0755";
                };
                enforce = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                };
              };
              directories = lib.mkOption {
                type = lib.types.attrsOf (lib.types.submodule directoryModule);
                default = { };
                description = "Provider-owned directories below the resource root.";
              };
              identities = {
                groups = lib.mkOption {
                  type = with lib.types; listOf nonEmptyStr;
                  default = [ ];
                };
                users = lib.mkOption {
                  type = with lib.types; listOf nonEmptyStr;
                  default = [ ];
                };
              };
              nfs = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.submodule {
                    options = {
                      fsid = lib.mkOption {
                        type = lib.types.ints.unsigned;
                        description = "Stable NFS filesystem identifier.";
                      };
                      anonymousIdentity = lib.mkOption {
                        type = with lib.types; nullOr nonEmptyStr;
                        default = null;
                      };
                    };
                  }
                );
                default = null;
                description = "NFS export policy for the ${name} resource.";
              };
            };
          }
        )
      );
      default = { };
      description = "Durable storage resources provided by this host.";
    };

    claims = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              provider = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "NixOS host providing this storage claim.";
              };
              resource = lib.mkOption {
                type = lib.types.nonEmptyStr;
                default = name;
                description = "Named resource requested from the provider.";
              };
              mountPoint = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Stable local path where the resource is presented.";
              };
              directories = lib.mkOption {
                type = lib.types.attrsOf (lib.types.submodule directoryModule);
                default = { };
                description = "Directories requested from the resource provider.";
              };
              attachments = lib.mkOption {
                type = lib.types.attrsOf (lib.types.submodule { });
                default = { };
                description = "Systemd service units attached to this mounted storage claim.";
              };
            };
          }
        )
      );
      default = { };
      description = "Storage resources consumed by this host.";
    };
  };
}
