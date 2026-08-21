{
  config,
  lib,
  pkgs,
  ...
}:
let
  sources = config.testSupport.sops.sources;
  templateSources = lib.mapAttrs (
    name: template: pkgs.writeText "test-sops-template-${name}" template.content
  ) config.sops.templates;
  install =
    {
      group,
      mode,
      owner,
      path,
      source,
    }:
    ''
      install -D -m ${lib.escapeShellArg mode} -o ${
        lib.escapeShellArg (if owner == null || builtins.stringLength owner == 0 then "root" else owner)
      } -g ${
        lib.escapeShellArg (if group == null || builtins.stringLength group == 0 then "root" else group)
      } ${lib.escapeShellArg source} ${lib.escapeShellArg path}
    '';
  secretCommands = lib.mapAttrsToList (
    name: secret:
    install {
      inherit (secret)
        group
        mode
        owner
        path
        ;
      source = sources.${name} or "/dev/null";
    }
  ) config.sops.secrets;
  templateCommands = lib.mapAttrsToList (
    name: template:
    install {
      inherit (template)
        group
        mode
        owner
        path
        ;
      source = templateSources.${name};
    }
  ) config.sops.templates;
  installSops = pkgs.writeShellApplication {
    name = "install-test-sops";
    runtimeInputs = [ pkgs.coreutils ];
    text = lib.concatStringsSep "\n" (secretCommands ++ templateCommands);
  };
in
{
  options.testSupport.sops.sources = lib.mkOption {
    type = with lib.types; attrsOf path;
    default = { };
    description = "Plaintext source files installed for declared sops-nix secrets in a NixOS test.";
  };

  config = {
    assertions = [
      {
        assertion = lib.all (name: builtins.hasAttr name config.sops.secrets) (builtins.attrNames sources);
        message = "testSupport.sops.sources contains a source for an undeclared sops-nix secret.";
      }
    ];

    sops = {
      age.keyFile = "/var/empty/nixos-test-sops-age-key";
      defaultSopsFile = pkgs.writeText "empty-test-secrets.yaml" "{}\n";
      useSystemdActivation = true;
      validateSopsFiles = false;
    };

    systemd.services.sops-install-secrets.serviceConfig.ExecStart = lib.mkForce [
      (lib.getExe installSops)
    ];
  };
}
