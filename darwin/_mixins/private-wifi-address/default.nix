{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.networking.privateWifiAddress;
  airportPreferences = "/Library/Preferences/SystemConfiguration/com.apple.airport.preferences";
  knownNetworks = "/Library/Preferences/com.apple.wifi.known-networks";
  applyKnownNetwork = ssid: ''
    ssid=${lib.escapeShellArg ssid}
    network_key="wifi.network.ssid.$ssid"

    echo "Setting Private Wi-Fi Address off for network: $ssid"
    if ! /usr/bin/defaults write ${lib.escapeShellArg knownNetworks} "$network_key" -dict-add PrivateMACAddressModeUserSetting -string off; then
      echo "Failed to set Private Wi-Fi Address off for network: $ssid" >&2
      private_wifi_address_failures=$((private_wifi_address_failures + 1))
    fi
  '';
in
{
  options.host.networking.privateWifiAddress = {
    enable = lib.mkEnableOption "Darwin Private Wi-Fi Address override";

    networks = lib.mkOption {
      type = with lib.types; listOf str;
      default = hostInventory.site.wifi.privateWifiAddressDisabledSsids or [ ];
      example = [
        "home-wifi"
      ];
      description = ''
        Wi-Fi SSIDs where Private Wi-Fi Address should be set to off.
        When empty, set the system default so new networks use the hardware MAC address.
      '';
    };
  };

  config = lib.mkMerge [
    {
      host.networking.privateWifiAddress.enable = lib.mkDefault config.host.networking.enable;
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = lib.all (ssid: !(lib.hasInfix "\n" ssid) && !(lib.hasInfix "\r" ssid)) cfg.networks;
          message = "host.networking.privateWifiAddress.networks entries must not contain newlines.";
        }
      ];

      system.activationScripts.postActivation.text = lib.mkAfter (
        if cfg.networks == [ ] then
          ''
            echo "Setting Private Wi-Fi Address off by default for Darwin Wi-Fi networks."
            # Counterintuitively, 1 disables private MACs by default.
            if ! /usr/bin/defaults write ${lib.escapeShellArg airportPreferences} PrivateMACAddressModeSystemSetting -int 1; then
              echo "Failed to set Private Wi-Fi Address off by default for Darwin Wi-Fi networks." >&2
              exit 1
            fi
            /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
          ''
        else
          ''
            echo "Setting Private Wi-Fi Address off for configured Darwin Wi-Fi networks."
            private_wifi_address_failures=0
            ${lib.concatMapStrings applyKnownNetwork cfg.networks}
            if [ "$private_wifi_address_failures" -gt 0 ]; then
              echo "Failed to set Private Wi-Fi Address off for $private_wifi_address_failures configured network(s)." >&2
              exit 1
            fi
            /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
          ''
      );
    })
  ];
}
