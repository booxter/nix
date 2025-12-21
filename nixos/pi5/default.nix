{ pkgs, ... }:
let
  mainIface = "end0";
  guestIface = "wlan0";
  gwAddr = "192.168.0.1";
  mainAddr = "192.168.1.1";
  guestAddr = "192.168.2.1";
in
{
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
  networking.wireless.networks = {
    booxter-guest = { };
  };

  # TODO: enable ipv6
  # TODO: use secret management for internal info?
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = true;
    settings = {
      dhcp-authoritative = true;
      dhcp-rapid-commit = true;

      dhcp-range = [
        # TODO: exclude 192.168.15.0/24?
        "${mainIface},192.168.10.1,192.168.20.255"
        "${guestIface},192.168.100.1,192.168.100.255"
      ];

      listen-address = [
        "127.0.0.1"
        mainAddr
        guestAddr
      ];

      dhcp-option = [
        "option:router,${gwAddr}"
        "${mainIface},option:dns-server,${mainAddr}"
        "${guestIface},option:dns-server,${gwAddr}"
      ];

      server = [ gwAddr ];

      domain-needed = true;

      host-record = [
        "egress,${gwAddr}"
        "dhcp,${mainAddr}"
      ];

      # TODO: parametrize, eg.: https://github.com/kradalby/dotfiles/blob/6bae60204e1caab84262b2b1b7be013eeec80547/machines/dev.ldn/dnsmasq.nix
      dhcp-host = [
        # infra
        "7c:b7:7b:04:05:99,mdx,192.168.10.100" # MDX-8

        # clients
        "id:mmini,mmini,192.168.11.1"
        "id:JGWXHWDL4X,mlt,192.168.11.2" # use something more readable
        "id:mair,mair,192.168.11.3"
        "id:frame,frame,192.168.11.4"

        # DON'T USE 192.168.15.0/24 for nixarr compatibility
        # TODO: migrate all internal nodes out of .15 range for nixarr compatibility
        # TODO: modify nixarr to allow using a different range for wg iface?

        #---- lab ----
        "78:2d:7e:24:2d:f9,sw-lab,192.168.15.1" # switch

        # ports: 8000 (http), 8001 (https)
        "78:72:64:43:9c:3f,nas-lab,192.168.16.2" # asustor

        # mini-PC NUC nodes running proxmox
        "38:05:25:30:7d:89,prx1-lab,192.168.15.10"
        "38:05:25:30:7f:7d,prx2-lab,192.168.15.11"
        "38:05:25:30:7d:69,prx3-lab,192.168.15.12"

        # nv ws
        "ac:b4:80:40:05:2e,nvws,192.168.15.100"
      ];

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
  networking.firewall.allowedUDPPorts = [
    53 # DNS
    67 # DHCP
    69 # TFTP
    514 # syslog
  ];
  systemd.tmpfiles.rules = [
    "L+ /var/lib/dnsmasq/tftp/netboot.xyz.efi - - - - ${pkgs.netbootxyz-efi}"
  ];

  # syslogd -r for remote debugging
  services.syslogd = {
    enable = true;
    enableNetworkInput = true;
  };
}
