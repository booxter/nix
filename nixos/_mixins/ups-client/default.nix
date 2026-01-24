{ ... }:
{
  # TODO: rotate this password and migrate to sops-managed secrets.
  environment.etc."nut/upsadmin.pass" = {
    text = "AdmUps1111\n";
    mode = "0600";
  };

  power.ups = {
    enable = true;
    mode = "netclient";
    upsmon.monitor.nas = {
      system = "ASUSTOR-UPS@nas-lab";
      user = "upsadmin";
      passwordFile = "/etc/nut/upsadmin.pass";
      type = "slave";
    };
  };
}
