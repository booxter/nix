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
    host.nix.nixpkgs-review.additional-builders = lib.filter (
      builder: builder.hostName == "linux-builder"
    ) config.nix.buildMachines;

    assertions = [
      {
        assertion = cfg.acceptLicense;
        message = "The Rosetta Linux builder requires host.nix.rosetta.acceptLicense";
      }
    ];

    nix.linux-builder = {
      enable = true;
      maxJobs = 4;
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
      config.virtualisation.cores = 8;
      config.virtualisation.memorySize = lib.mkForce 8192;
      config.virtualisation.vz.nestedVirtualization = true;
    };

    launchd.daemons.linux-builder.serviceConfig = {
      StandardOutPath = "/var/log/nix-darwin/linux-builder.log";
      StandardErrorPath = "/var/log/nix-darwin/linux-builder.log";
    };

    system.activationScripts.preActivation.text = lib.mkIf cfg.acceptLicense (
      lib.mkBefore ''
        if ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
          echo "Installing Rosetta and accepting its license."
          /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        fi
      ''
    );
  };
}
