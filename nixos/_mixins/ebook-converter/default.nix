{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.ebookConverter;
in
{
  imports = [ ./service.nix ];

  options.host.ebookConverter = {
    enable = lib.mkEnableOption "ebook library format reconciliation";

    package = lib.mkOption {
      type = lib.types.package;
      default = import ./package { inherit pkgs; };
      description = "Ebook converter package to run.";
    };

    library = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Registered ebook library to reconcile.";
    };

    stateDir = lib.mkOption {
      type = lib.types.strMatching "^/.*";
      default = "/var/lib/ebook-converter";
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "ebook-converter";
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media";
    };
  };

  config.assertions = lib.optionals cfg.enable [
    {
      assertion = cfg.library != null && builtins.hasAttr cfg.library config.host.media.libraries;
      message = "host.ebookConverter.library must select a registered media library";
    }
    {
      assertion =
        cfg.library == null
        || !builtins.hasAttr cfg.library config.host.media.libraries
        || config.host.media.libraries.${cfg.library}.contentType == "ebooks";
      message = "host.ebookConverter.library must select an ebook library";
    }
  ];
}
