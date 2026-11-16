# Run from the repository root using the configured Linux builders:
# nix build --impure --no-link -L --expr '
#   let flake = builtins.getFlake (toString ./.);
#       pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
#   in import ./tests/reproducers/cake-blue-decay.nix { inherit pkgs; }'
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "cake-blue-decay-reproducer";

  # This diagnostic expects the bug to reproduce; it is deliberately outside
  # tests/nixos, whose tests are collected as normal regression checks.
  nodes = {
    receiver = {
      boot.kernelModules = [
        "ifb"
        "sch_cake"
      ];
      networking.firewall.enable = false;
      environment.systemPackages = [
        pkgs.iperf3
        pkgs.iproute2
      ];
    };
    sender = {
      networking.firewall.enable = false;
      environment.systemPackages = [ pkgs.iperf3 ];
    };
  };

  testScript = builtins.readFile ./cake-blue-decay.py;
}
