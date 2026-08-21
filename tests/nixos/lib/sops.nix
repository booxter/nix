{
  config,
  lib,
  pkgs,
  ...
}:
let
  sourceFiles = config.testSupport.sops.sources;
  values = config.testSupport.sops.values;
  valueSources = lib.mapAttrs (
    name: value:
    pkgs.writeText "test-sops-value-${lib.replaceStrings [ "/" ] [ "-" ] name}" "${value}\n"
  ) values;
  sources = sourceFiles // valueSources;
  duplicateSources = lib.intersectLists (builtins.attrNames sourceFiles) (builtins.attrNames values);
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
  options.testSupport.sops = {
    sources = lib.mkOption {
      type = with lib.types; attrsOf path;
      default = { };
      description = "Plaintext source files installed for declared sops-nix secrets in a NixOS test.";
    };

    values = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = { };
      description = "Plaintext values installed for declared sops-nix secrets in a NixOS test.";
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.all (name: builtins.hasAttr name config.sops.secrets) (builtins.attrNames sources);
        message = "testSupport.sops contains a fixture for an undeclared sops-nix secret.";
      }
      {
        assertion = duplicateSources == [ ];
        message = "testSupport.sops values and sources define the same secret: ${lib.concatStringsSep ", " duplicateSources}";
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
