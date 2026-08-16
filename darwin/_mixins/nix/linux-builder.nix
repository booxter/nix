{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.rosetta;
in
{
  options.host.nix.rosetta.acceptLicense = lib.mkEnableOption ''
    installation of Rosetta after accepting Apple's software license agreement
  '';

  config = {
    assertions = [
      {
        assertion = cfg.acceptLicense;
        message = "The Rosetta Linux builder requires host.nix.rosetta.acceptLicense";
      }
    ];

    nix.linux-builder = {
      enable = true;
      package = pkgs.darwin.linux-builder-vz;
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      supportedFeatures = [
        "benchmark"
        "big-parallel"
        "kvm"
        "nixos-test"
      ];
      config.virtualisation.vz.nestedVirtualization = true;
    };

    launchd.daemons.linux-builder.serviceConfig = {
      StandardOutPath = "/var/log/nix-darwin/linux-builder.log";
      StandardErrorPath = "/var/log/nix-darwin/linux-builder.log";
    };

    system.activationScripts.preActivation.text = lib.mkIf cfg.acceptLicense (
      lib.mkBefore ''
        echo "Installing Rosetta and accepting its license if needed."
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license
      ''
    );
  };
}
