{ pkgs, hostname, ... }:
let
  netIface = "end0";
in
{
  networking = {
    interfaces.end0 = {
      ipv4.addresses = [
        {
          address = "192.168.1.1";
          prefixLength = 16;
        }
      ];
    };
    defaultGateway = {
      address = "192.168.0.1";
      interface = netIface;
    };
    nameservers = [
      "192.168.0.1"
    ];
  };

  networking.wireless.enable  = true;
  networking.wireless.networks  = {
    booxter-guest = {};
  };

  # TODO: enable ipv6
  # TODO: use secret management for internal info?
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = true;
    settings = {
      interface = netIface;
      dhcp-authoritative = true;
      dhcp-rapid-commit = true;

      dhcp-range = [ "192.168.10.1,192.168.20.255" ];

      listen-address = [ "192.168.1.1" ];

      dhcp-option = [
        "option:router,192.168.0.1"
        "option:dns-server,192.168.1.1"
      ];

      server = [
        "192.168.0.1"
      ];

      domain-needed = true;

      host-record = [
        "egress,192.168.0.1"
        "dhcp,192.168.1.1"
      ];

      # TODO: parametrize, eg.: https://github.com/kradalby/dotfiles/blob/6bae60204e1caab84262b2b1b7be013eeec80547/machines/dev.ldn/dnsmasq.nix
      dhcp-host = [
        # infra
        "7c:b7:7b:04:05:99,mdx,192.168.10.100" # MDX-8

        # clients (wifi)
        "id:mmini,mmini,192.168.11.1"
        "id:ihrachyshka-mlt,ihrachyshka-mlt,192.168.11.2"
        "id:mair,mair,192.168.11.3"

        # lab
        "78:2d:7e:24:2d:f9,sw-lab,192.168.15.1" # switch
        "78:72:64:43:9c:3f,nas-lab,192.168.15.2" # asustor

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
  ];
  systemd.tmpfiles.rules = [
    "L+ /var/lib/dnsmasq/tftp/netboot.xyz.efi - - - - ${pkgs.netbootxyz-efi}"
  ];
}
