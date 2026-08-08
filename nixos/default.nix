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
      ./_mixins/adaptive-upload-policy
      ./_mixins/attic
      ./_mixins/auto-upgrade
      ./_mixins/avahi
      ./_mixins/backups
      ./_mixins/builder.nix
      ./_mixins/degoog
      ./_mixins/desktop-environment.nix
      ./_mixins/external-service.nix
      ./_mixins/hardware
      ./_mixins/home-assistant
      ./_mixins/internal-https-service.nix
      ./_mixins/jellyfin
      ./_mixins/llm
      ./_mixins/lolek
      ./_mixins/netboot.nix
      ./_mixins/nix
      ./_mixins/observability
      ./_mixins/paperless
      ./_mixins/paperless-gpt
      ./_mixins/pki
      ./_mixins/proxmox
      ./_mixins/public-ingress.nix
      ./_mixins/qos
      ./_mixins/remote-gui
      ./_mixins/remote-unlock.nix
      ./_mixins/sso
      ./_mixins/storage
      ./_mixins/unifi-sync
      ./_mixins/ups
      ./_mixins/user
      ./_mixins/vikunja
      ./_mixins/vm.nix
      ./_mixins/watchstate
      ./_mixins/wireguard-endpoint
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
