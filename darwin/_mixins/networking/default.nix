{
  hostname,
  isWork,
  lib,
  ...
}:
{
  # Can't configure networking on managed work devices
  networking = lib.optionalAttrs (!isWork) {
    knownNetworkServices =
      # mair - laptop - doesn't have builtin ethernet
      lib.optionals (hostname != "mair") [
        "Ethernet"
      ]
      ++ [
        "Wi-Fi"
      ];
    computerName = hostname;
    dhcpClientId = hostname;
  };
}
