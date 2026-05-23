{
  lib,
  pkgs,
  username,
  hostInventory,
  ...
}:
let
  lan = hostInventory.site.lan;
  beastAddress = hostInventory.dhcpReservationsByHostname.beast.ip;
  dhcpRanges = import ../../lib/dhcp-ranges.nix { inherit lib; };
  renderDhcpReservation =
    reservation:
    builtins.concatStringsSep "," (
      (reservation.identifiers or [ reservation.match ])
      ++ [
        reservation.hostname
        reservation.ip
      ]
    );
  renderDhcpRange = iface: range: "${iface},${range.start},${range.end}";
  mainIface = "end0";
  guestIface = "wlan0";
  gwAddr = lan.upstreamGateway;
  mainAddr = lan.gateway.address;
  guestAddr = lan.guest.address;
  lanDomain = lan.domain;
  dnsmasqExporterPort = 9153;
  publicServiceHosts = map (service: service.publicHost) hostInventory.publicServices;
  staticDhcpHosts = map renderDhcpReservation hostInventory.staticDhcpReservations;
  managedDhcpHosts = map renderDhcpReservation hostInventory.managedDhcpReservations;
  mainDhcpRanges = map (renderDhcpRange mainIface) lan.dhcpRanges.main.ranges;
  guestDhcpRanges = map (renderDhcpRange guestIface) lan.dhcpRanges.guest.ranges;
in
{
  imports = [
    ./ups.nix
  ];

  assertions =
    dhcpRanges.mkExclusionAssertions "main" lan.dhcpRanges.main
    ++ dhcpRanges.mkExclusionAssertions "guest" lan.dhcpRanges.guest;

  networking = {
    interfaces.end0 = {
      ipv4.addresses = [
        {
          address = mainAddr;
          prefixLength = 16;
        }
      ];
    };
    interfaces.wlan0 = {
      ipv4.addresses = [
        {
          address = guestAddr;
          prefixLength = 16;
        }
      ];
    };
    defaultGateway = {
      address = gwAddr;
      interface = mainIface;
    };
    nameservers = [
      gwAddr
    ];
  };

  networking.wireless.enable = true;
  # brcmfmac on the Pi 5 repeatedly fails wpa_supplicant scheduled background
  # scans after the uplink drops, which spams the journal and stalls recovery.
  networking.wireless.scanOnLowSignal = false;
  networking.wireless.networks = {
    booxter-guest = { };
  };

  # TODO: enable ipv6
  # TODO: use secret management for internal info?
  host.observability.dnsQueryAccounting.enable = true;

  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = true;
    settings = {
      dhcp-authoritative = true;
      dhcp-rapid-commit = true;

      dhcp-range = mainDhcpRanges ++ guestDhcpRanges;

      listen-address = [
        "127.0.0.1"
        mainAddr
        guestAddr
      ];

      dhcp-option = [
        "option:router,${gwAddr}"
        "${mainIface},option:dns-server,${mainAddr}"
        "${mainIface},option:domain-name,${lanDomain}"
        "${mainIface},option:domain-search,${lanDomain}"
        "${guestIface},option:dns-server,${gwAddr}"
      ];

      cache-size = 2000;
      # Include requester IP in dnsmasq query logs so Loki can answer
      # "which client generated this DNS traffic?"
      log-queries = "extra";
      server = [ gwAddr ];

      domain-needed = true;
      domain = lanDomain;
      expand-hosts = true;
      local = "/${lanDomain}/";
      cname = [
        "nix-cache,prox-cachevm"
      ];

      host-record = [
        "egress,${gwAddr}"
        "dhcp,${mainAddr}"
        # Split DNS: send public web domains to the central ingress on beast.
        "${lib.concatStringsSep "," publicServiceHosts},${beastAddress}"
      ];

      # TODO: parametrize, eg.: https://github.com/kradalby/dotfiles/blob/6bae60204e1caab84262b2b1b7be013eeec80547/machines/dev.ldn/dnsmasq.nix
      dhcp-host = [
      ]
      ++ staticDhcpHosts
      ++ managedDhcpHosts;

      enable-tftp = true;
      tftp-root = "/var/lib/dnsmasq/tftp";

      # Note: disable Secure Boot in BIOS.
      #
      # For proxmox VMs, the following configuration is required:
      # - Select EFI BIOS
      # - Add UEFI disk (don't enroll keys)
      # - Add virtio RNG device
      dhcp-boot = [
        "netboot.xyz.efi"
      ];
    };
  };
  services.prometheus.exporters.dnsmasq = {
    enable = true;
    listenAddress = mainAddr;
    openFirewall = false;
    port = dnsmasqExporterPort;
    dnsmasqListenAddress = "127.0.0.1:53";
  };
  networking.firewall.interfaces.${mainIface}.allowedTCPPorts = [
    53 # DNS over TCP fallback and observability probes
    dnsmasqExporterPort
  ];
  networking.firewall.allowedUDPPorts = [
    53 # DNS
    67 # DHCP
    69 # TFTP
  ];
  systemd.tmpfiles.rules = [
    "L+ /var/lib/dnsmasq/tftp/netboot.xyz.efi - - - - ${pkgs.netbootxyz-efi}"
  ];

  users.users.${username} = {
    hashedPassword = "$6$cgM30pIRZnRi0o21$qMkHs50CF.4Af4UWT.l/INY2nq3zAValESyaWj6mi.cvROO7cOjNXdttwCaEyQMaQAGzRlUJkkmJHUd.DFNxY0";
  };
}
