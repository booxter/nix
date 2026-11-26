{ lib, ... }:
{
  virtualisation.vmVariant = { config, pkgs, ... }: {
    virtualisation = {
      diskSize = 100 * 1024;
      graphics = lib.mkDefault false;
      macosVersion = "27.2";
      nixInstaller = {
        type = "nix";
        version = "2.35.6";
      };
      forwardedSockets.sops = {
        hostPath = "~/.ssh/sops/local.sock";
        guestPath = "/Users/${config.virtualisation.bootstrapUser}/.ssh/sops/vm.sock";
        lifetime = "vm";
      };
    };

    # A fresh headless guest cannot approve changes to System keychain trust.
    host.pki.requireSystemKeychainTrust = false;

    sops.package = pkgs.sops-install-secrets-with-keyservice;
    sops.environment.SOPS_KEYSERVICE = lib.optionalString (
      config.virtualisation.forwardedSockets ? sops
    ) "unix://${config.virtualisation.forwardedSockets.sops.guestPath}";

    # The operator hardware stays on the hypervisor; the guest only borrows its service.
    home-manager.users.${config.host.username} = {
      launchd.agents.sops-keyservice.enable = lib.mkForce false;
      home.sessionVariables = {
        SOPS_KEYSERVICE = config.sops.environment.SOPS_KEYSERVICE;
        SOPS_ENABLE_LOCAL_KEYSERVICE = "false";
      };
    };

    # Local configuration tests do not need to start another VM for Linux builds.
    nix.linux-builder.enable = lib.mkForce false;

    # The guest disk is smaller than the physical hosts' GC thresholds.
    nix.settings = {
      min-free = 4 * 1024 * 1024 * 1024;
      max-free = 8 * 1024 * 1024 * 1024;
    };
  };
}
