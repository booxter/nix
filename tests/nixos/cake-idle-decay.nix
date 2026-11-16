{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "cake-idle-decay";

  nodes = {
    receiver = {
      imports = [ ../../nixos/_mixins/qos/cake-idle-decay ];
      host.qos.cakeIdleDecay.enable = true;
      boot.kernelModules = [ "ifb" ];
      networking.firewall.enable = false;
      environment.systemPackages = [
        pkgs.iperf3
        pkgs.iproute2
      ];
    };
    sender = {
      imports = [ ../../nixos/_mixins/qos/cake-idle-decay ];
      networking.firewall.enable = false;
      environment.systemPackages = [ pkgs.iperf3 ];
    };
  };

  testScript = builtins.readFile ./cake-idle-decay/test.py;
}
