{
  lib,
  pkgs,
  ...
}:
{
  options.host.slskd = {
    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "slskd";
      description = "System user shared by all slskd instances.";
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media";
      description = "Group allowed to exchange completed downloads with consumers.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "the ${name} slskd instance";

              package = lib.mkOption {
                type = lib.types.package;
                default = pkgs.slskd;
                defaultText = lib.literalExpression "pkgs.slskd";
                description = "slskd package used by this instance.";
              };

              stateDir = lib.mkOption {
                type = lib.types.strMatching "^/.*";
                default = "/var/lib/slskd/${name}";
                description = "Persistent application state directory.";
              };

              secretPrefix = lib.mkOption {
                type = lib.types.nonEmptyStr;
                default = "slskd/${name}";
                description = "SOPS key prefix containing this instance's credentials.";
              };

              storage = {
                claim = lib.mkOption {
                  type = lib.types.nonEmptyStr;
                  description = "Storage claim containing this instance's downloads.";
                };

                relativePath = lib.mkOption {
                  type = lib.types.nonEmptyStr;
                  default = "slskd/${name}";
                  description = "Directory below the storage claim used by this instance.";
                };
              };

              api.port = lib.mkOption {
                type = lib.types.port;
                description = "HTTP API port inside the VPN namespace.";
              };

              vpn = {
                namespace = lib.mkOption {
                  type = lib.types.nonEmptyStr;
                  description = "VPN namespace containing this instance.";
                };

                peerPort = lib.mkOption {
                  type = lib.types.port;
                  description = "VPN-provider port forwarded to the Soulseek listener.";
                };
              };

              settings = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
                description = "Additional slskd configuration merged into the generated settings.";
              };
            };
          }
        )
      );
      default = { };
      description = "Host-local slskd instances.";
    };
  };
}
