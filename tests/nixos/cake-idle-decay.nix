{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "cake-idle-decay";

  nodes = {
    receiver = { lib, ... }: {
      imports = [ ../../nixos/_mixins/qos ];
      options.host.observability.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      config = {
        host.qos.cakeIdleDecay.enable = true;
        host.qos.interfaces.test = {
          device = "eth1";
          limits.download = {
            direction = "ingress";
            rateMbit = 10;
            match = {
              protocol = "udp";
              destinationPort = 5201;
            };
          };
        };
        boot.kernelModules = [ "ifb" ];
        networking.firewall.enable = false;
        environment.systemPackages = [
          pkgs.iperf3
          pkgs.iproute2
        ];
      };
    };
    sender = {
      imports = [ ../../nixos/_mixins/qos/cake-idle-decay ];
      networking.firewall.enable = false;
      environment.systemPackages = [ pkgs.iperf3 ];
    };
  };

  testScript = builtins.readFile ./cake-idle-decay/test.py;
}
