{
  lib,
  pkgs,
  wgTimerDeps,
  wgUnitDepsBase,
}:
{
  systemd.services."update-dynamic-ip" = {
    unitConfig = wgUnitDepsBase;
    path = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
      ExecStart =
        let
          cookiePath = "/data/.secret/mam.cookies";
        in
        pkgs.writeShellScript "update-dynamic-ip" ''
          set -euo pipefail

          cookie_path="${cookiePath}"
          tmp_cookie="$(mktemp)"
          trap 'rm -f "$tmp_cookie"' EXIT

          if [ ! -s "$cookie_path" ]; then
            echo "missing or empty MAM cookie jar at $cookie_path" >&2
            exit 1
          fi

          cp "$cookie_path" "$tmp_cookie"
          chmod 600 "$tmp_cookie"

          response="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
            -c "$tmp_cookie" \
            -b "$tmp_cookie" \
            https://t.myanonamouse.net/json/dynamicSeedbox.php)"

          if ! printf '%s' "$response" | ${pkgs.jq}/bin/jq -e '.Success == true' >/dev/null; then
            printf '%s\n' "$response" >&2
            exit 1
          fi

          install -m 600 "$tmp_cookie" "$cookie_path"
          printf '%s\n' "$response"
        '';
    };
    vpnconfinement = {
      enable = true;
      vpnnamespace = "wg";
    };
  };

  systemd.timers."update-dynamic-ip" = {
    wantedBy = [ "timers.target" ];
    # Keep the timer independent from wg restarts. The service itself remains
    # bound to wg.service, but the timer should stay scheduled so it can fire
    # again after the namespace comes back.
    unitConfig = wgTimerDeps;
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "10m";
      Unit = "update-dynamic-ip.service";
    };
  };
}
