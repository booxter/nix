{
  config,
  pkgs,
  username,
  hostInventory,
  ...
}:
let
  lan = hostInventory.site.lan;
  renderDhcpRange = iface: range: "${iface},${range.start},${range.end}";
  mainIface = "end0";
  guestIface = "wlan0";
  gwAddr = lan.gateway.address;
  hostSpec = hostInventory.nixosHostSpecsByName.${config.networking.hostName};
  mainAddr = hostSpec.lanAddress;
  guestAddr = hostSpec.guestAddress;
  guestDhcpRanges = map (renderDhcpRange guestIface) lan.dhcpRanges.guest.ranges;
in
{
  imports = [
    ./ups.nix
  ];

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
  services.dnsmasq = {
    enable = true;
    settings = {
      dhcp-authoritative = true;
      dhcp-rapid-commit = true;

      dhcp-range = guestDhcpRanges;

      listen-address = [
        guestAddr
      ];

      dhcp-option = [
        "${guestIface},option:router,${gwAddr}"
        "${guestIface},option:dns-server,${guestAddr}"
      ];

      cache-size = 2000;
      server = [ gwAddr ];

      domain-needed = true;
    };
  };
  services.atftpd = {
    enable = true;
    root = "/var/lib/tftp";
    extraOptions = [
      "--bind-address"
      mainAddr
    ];
  };
  networking.firewall.interfaces.${guestIface} = {
    allowedTCPPorts = [
      53 # DNS over TCP fallback for guest clients
    ];
    allowedUDPPorts = [
      53 # DNS
      67 # DHCP
    ];
  };
  networking.firewall.interfaces.${mainIface}.allowedUDPPorts = [
    69 # TFTP
  ];
  systemd.tmpfiles.rules = [
    "L+ /var/lib/tftp/netboot.xyz.efi - - - - ${pkgs.netbootxyz-efi}"
  ];

  users.users.${username} = {
    hashedPassword = "$6$cgM30pIRZnRi0o21$qMkHs50CF.4Af4UWT.l/INY2nq3zAValESyaWj6mi.cvROO7cOjNXdttwCaEyQMaQAGzRlUJkkmJHUd.DFNxY0";
  };
}
