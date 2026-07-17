{
  config,
  lib,
  pkgs,
  ...
}:
let
  jellyfinApiKeyFile = config.sops.secrets."jellyfin/apiKey".path;
  waitForJellyfinIdle = pkgs.writeShellApplication {
    name = "wait-for-jellyfin-idle";
    runtimeInputs = [
      config.systemd.package
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      retry_delay_seconds=30

      while true; do
        if ! systemctl is-active --quiet jellyfin.service; then
          echo "Jellyfin is not active; maintenance may proceed."
          exit 0
        fi

        api_key="$(tr -d '\r\n' < ${lib.escapeShellArg jellyfinApiKeyFile})"
        if ! sessions="$({
          printf 'X-Emby-Token: %s\n' "$api_key"
        } | curl \
          --disable \
          --connect-timeout 5 \
          --fail \
          --header @- \
          --max-time 10 \
          --silent \
          --show-error \
          http://127.0.0.1:8096/Sessions)"; then
          echo "Unable to query active Jellyfin sessions; retrying in ''${retry_delay_seconds}s." >&2
          sleep "$retry_delay_seconds"
          continue
        fi

        if ! active_sessions="$(
          jq --compact-output --exit-status \
            'if type == "array" then [.[] | select(.NowPlayingItem? != null)] else error("expected a session array") end' \
            <<<"$sessions"
        )"; then
          echo "Jellyfin returned an invalid sessions response; retrying in ''${retry_delay_seconds}s." >&2
          sleep "$retry_delay_seconds"
          continue
        fi

        active_count="$(jq 'length' <<<"$active_sessions")"
        if [ "$active_count" -eq 0 ]; then
          echo "No active Jellyfin playback; maintenance may proceed."
          exit 0
        fi

        echo "Holding maintenance for $active_count active Jellyfin playback session(s):" >&2
        jq --raw-output '
          .[] |
          "  - \(.UserName // "unknown user"): \(.NowPlayingItem.Name // "unknown item") (\(if (.PlayState.IsPaused // false) then "paused" else "playing" end))"
        ' <<<"$active_sessions" >&2
        echo "Retrying in ''${retry_delay_seconds}s. Use deploy --no-inhibit to override a manual deployment." >&2
        sleep "$retry_delay_seconds"
      done
    '';
  };
  waitForJellyfinIdleExe = lib.getExe waitForJellyfinIdle;
in
{
  # This is the authoritative activation gate. It runs after the new system is
  # built but before services are stopped or restarted, covering auto-upgrades
  # and manual `deploy --switch` operations without a check/build race.
  system.preSwitchChecks.jellyfinPlayback = ''
    if [ "''${2-}" = switch ]; then
      ${waitForJellyfinIdleExe}
    fi
  '';

  # Avoid starting a potentially expensive unattended build while playback is
  # already active. The pre-switch check above repeats the check at activation.
  systemd.services.nixos-upgrade.serviceConfig = {
    ExecStartPre = [ waitForJellyfinIdleExe ];
    TimeoutStartSec = "infinity";
  };

  # Critical hosts reboot separately from their daily auto-upgrade switch.
  systemd.services.nixos-weekly-reboot-if-needed.serviceConfig = {
    ExecStartPre = [ waitForJellyfinIdleExe ];
    TimeoutStartSec = "infinity";
  };
}
