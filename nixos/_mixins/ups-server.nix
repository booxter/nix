{
  pkgs,
  upsName,
  upsDescription,
  shutdownDelaySeconds ? 600,
  isCriticalNode ? false,
  upsmonPasswordText,
  upsslavePasswordText,
  ...
}:
{
  imports = [
    (import ./ups-sched.nix { inherit pkgs shutdownDelaySeconds isCriticalNode; })
  ];

  environment.etc."nut/upsmon.pass" = {
    text = "${upsmonPasswordText}\n";
    mode = "0600";
  };
  environment.etc."nut/upsslave.pass" = {
    text = "${upsslavePasswordText}\n";
    mode = "0600";
  };

  power.ups = {
    enable = true;
    mode = "netserver";
    openFirewall = true;

    ups.${upsName} = {
      driver = "usbhid-ups"; # TODO: confirm the driver for this APC model.
      port = "auto";
      description = upsDescription;
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
      system = upsName;
      user = "upsmon";
      type = "master";
    };
  };
}
