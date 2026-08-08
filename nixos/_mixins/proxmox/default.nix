{
  config,
  hostInventory,
  hostSpec,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  realmProxmox = hostInventory.realms.${config.host.realm}.services.proxmox or null;
  clusters = if realmProxmox == null then { } else realmProxmox.clusters;
  realmClusterNames = builtins.attrNames clusters;
  clusterNames = builtins.attrNames (
    lib.filterAttrs (_: cluster: builtins.elem hostSpec.name cluster.nodes) clusters
  );
  clusterName = if builtins.length clusterNames == 1 then builtins.head clusterNames else null;
  isVM = hostSpec.isVM or false;
  requestedProxNode = hostSpec.proxNode or null;
  vmClusterNames =
    if requestedProxNode == null then
      realmClusterNames
    else
      builtins.attrNames (
        lib.filterAttrs (_: cluster: builtins.elem requestedProxNode cluster.nodes) clusters
      );
  vmClusterName = if builtins.length vmClusterNames == 1 then builtins.head vmClusterNames else null;
  vmCluster = if vmClusterName == null then null else clusters.${vmClusterName};
  proxNode =
    if requestedProxNode != null then
      requestedProxNode
    else if vmCluster != null then
      vmCluster.defaultVmNode
    else
      "";
  bridgeName = "vmbr0";
  macAddress = hostSpec.macAddress or null;
  cores = hostSpec.cores or 4;
  memorySize = hostSpec.memorySize or 8;
  balloonSize = hostSpec.balloonSize or null;
  diskSize = hostSpec.diskSize or 100;
  dhcpReservation = hostSpec.dhcpReservation or null;
in
{
  imports = [
    ./integrations.nix
    inputs.proxmox-nixos.nixosModules.proxmox-ve
  ]
  ++ lib.optionals isVM [
    inputs.proxmox-nixos.nixosModules.declarative-vms
  ];

  options.host.isProxmox = lib.mkOption {
    type = lib.types.bool;
    default = clusterName != null;
    readOnly = true;
    internal = true;
    description = "Whether this host is a Proxmox VE node.";
  };

  options.host.proxmox.cluster = lib.mkOption {
    type = with lib.types; nullOr str;
    default = clusterName;
    readOnly = true;
    internal = true;
    description = "Proxmox cluster containing this host.";
  };

  config = lib.mkMerge (
    [
      {
        assertions = [
          {
            assertion = builtins.length clusterNames <= 1;
            message = "host ${hostSpec.name} may belong to at most one Proxmox cluster";
          }
        ]
        ++ lib.optionals isVM [
          {
            assertion = vmCluster != null;
            message =
              if requestedProxNode == null then
                "VM ${hostSpec.name} requires exactly one Proxmox cluster in realm ${config.host.realm}"
              else
                "VM ${hostSpec.name} proxNode ${requestedProxNode} must belong to exactly one Proxmox cluster in realm ${config.host.realm}";
          }
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (name: cluster: [
            {
              assertion = lib.all (node: builtins.hasAttr node hostInventory.nixosHosts) cluster.nodes;
              message = "Proxmox cluster ${config.host.realm}.${name} contains an unknown node";
            }
            {
              assertion = lib.all (
                node:
                !(builtins.hasAttr node hostInventory.nixosHosts)
                || hostInventory.nixosHosts.${node}.realm == config.host.realm
              ) cluster.nodes;
              message = "Proxmox cluster ${config.host.realm}.${name} nodes must belong to their cluster realm";
            }
            {
              assertion = builtins.elem cluster.defaultVmNode cluster.nodes;
              message = "Proxmox cluster ${config.host.realm}.${name} defaultVmNode must be a cluster node";
            }
            {
              assertion = !(cluster ? oidcManagerHost) || builtins.elem cluster.oidcManagerHost cluster.nodes;
              message = "Proxmox cluster ${config.host.realm}.${name} oidcManagerHost must be a cluster node";
            }
            {
              assertion = !(cluster ? monitoringNode) || builtins.elem cluster.monitoringNode cluster.nodes;
              message = "Proxmox cluster ${config.host.realm}.${name} monitoringNode must be a cluster node";
            }
          ]) clusters
        );
      }
      (lib.mkIf config.host.isProxmox {
        nixpkgs.overlays = [
          inputs.proxmox-nixos.overlays.${hostSpec.platform}
          (
            _final: prev:
            let
              patchedPveManager = prev.pve-manager.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [
                  ../../../patches/pve-manager-disable-subscription-popup.patch
                ];
              });
            in
            {
              pve-manager = patchedPveManager;
              proxmox-ve = prev.proxmox-ve.override {
                pve-manager = patchedPveManager;
              };
            }
          )
        ];

        services.proxmox-ve = {
          ipAddress = hostSpec.ipAddress;
          enable = true;
          bridges = [ bridgeName ];
        };

        # Some packages useful when debugging Proxmox VE.
        environment.systemPackages = with pkgs; [ bridge-utils ];

        # Bridge to the LAN, while retaining the IP address and MAC address on
        # the main interface as expected by the DHCP server.
        networking.useNetworkd = true;
        systemd.network.enable = true;

        services.resolved.settings.Resolve.ResolveUnicastSingleLabel = true;

        systemd.network.networks."10-lan" = {
          matchConfig.Name = [ config.host.network.primaryInterface ];
          networkConfig.Bridge = bridgeName;
        };

        systemd.network.netdevs."10-lan-bridge".netdevConfig = {
          Name = bridgeName;
          Kind = "bridge";
        }
        // inputs.nixpkgs.lib.optionalAttrs (macAddress != null) {
          MACAddress = macAddress;
        };

        systemd.network.networks."10-lan-bridge" = {
          matchConfig.Name = bridgeName;
          networkConfig = {
            IPv6AcceptRA = true;
            DHCP = "ipv4";
          };
          dhcpV4Config = {
            # systemd-networkd receives DOMAINNAME=home.arpa from DHCP, but does
            # not install it as a search domain unless enabled.
            UseDomains = true;
          };
          linkConfig.RequiredForOnline = "routable";
        };
      })
    ]
    ++ lib.optional isVM {
      virtualisation.proxmox = {
        inherit cores;
        name = hostSpec.name;
        node = proxNode;
        autoInstall = true;
        memory = memorySize * 1024;
        balloon = if balloonSize == null then null else balloonSize * 1024;
        cpu.cputype = "host";
        agent = {
          enabled = true;
          type = "virtio";
          freeze-fs-on-backup = true;
          fstrim_cloned_disks = true;
        };
        net = [
          (
            {
              model = "virtio";
              bridge = bridgeName;
            }
            // inputs.nixpkgs.lib.optionalAttrs (dhcpReservation != null) {
              macaddr = dhcpReservation.match;
            }
          )
        ];
        scsi = [
          {
            file = "local:${toString diskSize}";
            discard = "on";
          }
        ];
        onboot = true;
      };

      boot.growPartition = true;
    }
    ++ lib.optional isVM (
      lib.mkIf config.host.isProxmox {
        virtualisation.vmVariant.virtualisation.forwardPorts = [
          {
            from = "host";
            guest.port = 8006;
            host.port = 8006;
          }
        ];
      }
    )
  );
}
