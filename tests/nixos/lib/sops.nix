{
  config,
  lib,
  pkgs,
  ...
}:
let
  sources = config.testSupport.sops.sources;
  installSecrets = pkgs.writeShellApplication {
    name = "install-test-secrets";
    runtimeInputs = [ pkgs.coreutils ];
    text = lib.concatMapStringsSep "\n" (
      name:
      let
        secret = config.sops.secrets.${name};
        source = sources.${name} or "/dev/null";
      in
      ''
        install -D -m ${lib.escapeShellArg secret.mode} -o ${lib.escapeShellArg secret.owner} -g ${lib.escapeShellArg secret.group} ${lib.escapeShellArg source} ${lib.escapeShellArg secret.path}
      ''
    ) (builtins.attrNames config.sops.secrets);
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
      (lib.getExe installSecrets)
    ];
  };
}
