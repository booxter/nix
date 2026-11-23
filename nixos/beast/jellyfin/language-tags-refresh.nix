{
  config,
  lib,
  pkgs,
  ...
}:
let
  name = "jellyfin-language-tags-refresh";
  refreshWeek = pkgs.writeShellScript "${name}-week" ''
    date=${lib.getExe' pkgs.coreutils "date"}

    # Anchor the cadence two weeks after the last full refresh. UTC week
    # boundaries keep alternate Sundays aligned through DST and year changes.
    anchor="$("$date" --utc --date=2026-11-29 +%s)" || exit 255
    now="$("$date" +%s)" || exit 255

    (( now >= anchor && (now - anchor) / (7 * 24 * 60 * 60) % 2 == 0 ))
  '';
  waitForRefresh = pkgs.writeShellScript "wait-for-${name}" ''
    while true; do
      state="$(${config.systemd.package}/bin/systemctl show --property=ActiveState --value ${name}.service)" || exit 1

      # A oneshot stays activating while its request is running.
      case "$state" in
        activating|active|deactivating)
          ${lib.getExe' pkgs.coreutils "sleep"} 30
          ;;
        *)
          exit 0
          ;;
      esac
    done
  '';
  dependencies = [
    "jellyfin.service"
    "sops-install-secrets.service"
  ];
in
{
  host.maintenance.guards.${name} = "${waitForRefresh}";

  systemd.services.${name} = {
    description = "Force a full refresh of Jellyfin language tags";
    requires = dependencies;
    after = dependencies;
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      LoadCredential = "api-key:${config.sops.secrets."jellyfin/apiKey".path}";
      TimeoutStartSec = "4h";
      ExecCondition = refreshWeek;
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.curl)
        "--silent"
        "--show-error"
        "--fail"
        "--connect-timeout"
        "10"
        "--noproxy"
        "*"
        "--request"
        "POST"
        "--variable"
        "api_key@%d/api-key"
        "--expand-header"
        ''Authorization: MediaBrowser Token="{{api_key:trim}}"''
        "http://127.0.0.1:8096/LanguageTags/RefreshLanguageTags?type=everything"
      ];
    };
  };

  systemd.timers.${name} = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:00";
      Persistent = false;
    };
  };
}
