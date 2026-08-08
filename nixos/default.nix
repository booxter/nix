{
  config,
  hostInventory,
  hostSpec,
  inputs,
  lib,
  ...
}:
let
  username = hostSpec.username;
in
(
  {
    imports = [
      inputs.stylix.nixosModules.stylix
      ../common
      inputs.sops-nix.nixosModules.sops
      inputs.home-manager.nixosModules.home-manager
    ]
    ++ [
      ./_mixins/attic
      ./_mixins/auto-upgrade
      ./_mixins/backups
      ./_mixins/builder.nix
      ./_mixins/desktop-environment.nix
      ./_mixins/hardware
      ./_mixins/llm
      ./_mixins/lolek
      ./_mixins/network
      ./_mixins/nix
      ./_mixins/observability
      ./_mixins/pki
      ./_mixins/proxmox
      ./_mixins/remote-gui
      ./_mixins/remote-unlock.nix
      ./_mixins/sso
      ./_mixins/storage
      ./_mixins/ups
      ./_mixins/user
      ./_mixins/vm.nix
      ./_mixins/web
      ./_mixins/yubi.nix
    ];

    home-manager = {
      extraSpecialArgs = {
        inherit
          hostInventory
          hostSpec
          inputs
          ;
      };
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${username} = ../hm;
    };
    virtualisation.containers.enable = true;
    security.sudo.wheelNeedsPassword = lib.mkDefault config.host.management.sudoWheelNeedsPassword;
    time.timeZone = hostInventory.regional.timeZone;
    i18n.defaultLocale = hostInventory.regional.posixLocale;

    # TODO: revisit hw sensor monitoring (sensord or alternative).

  }
  // {
    # Install regular secrets through a sysinit unit so services that consume
    # them can order themselves after sops-install-secrets.service. Password
    # secrets marked neededForUsers still use the early users activation path.
    sops.useSystemdActivation = lib.mkDefault true;
  }
)
