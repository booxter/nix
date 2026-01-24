{ pkgs, ... }:
let
  shutdownDelaySeconds = 900;
in
{
  imports = [
    (import ../_mixins/ups-sched.nix { inherit pkgs shutdownDelaySeconds; })
  ];

  # TODO: rotate these passwords and migrate to sops-managed secrets.
  environment.etc."nut/upsmon.pass" = {
    text = "upsmon123\n";
    mode = "0600";
  };
  environment.etc."nut/upsslave.pass" = {
    text = "upsslave123\n";
    mode = "0600";
  };

  power.ups = {
    enable = true;
    mode = "netserver";
    openFirewall = true;

    ups."PI5-UPS" = {
      driver = "usbhid-ups"; # TODO: confirm the driver for this APC model.
      port = "auto";
      description = "APC UPS 1500VA";
    };

    upsd.listen = [
      { address = "0.0.0.0"; }
      { address = "::"; }
    ];

    users = {
      upsmon = {
        passwordFile = "/etc/nut/upsmon.pass";
        upsmon = "primary";
      };
      upsslave = {
        passwordFile = "/etc/nut/upsslave.pass";
        upsmon = "secondary";
      };
    };

    upsmon.monitor.local = {
      system = "PI5-UPS";
      user = "upsmon";
      type = "master";
    };
  };
}
