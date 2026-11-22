{
  config,
  lib,
  pkgs,
  ...
}:
let
  refreshWeek = pkgs.writeShellScript "jellyfin-language-tags-refresh-week" ''
    date=${lib.getExe' pkgs.coreutils "date"}

    # Anchor the cadence two weeks after the last full refresh. UTC week
    # boundaries keep alternate Sundays aligned through DST and year changes.
    anchor="$("$date" --utc --date=2026-11-29 +%s)" || exit 255
    now="$("$date" +%s)" || exit 255

    (( now >= anchor && (now - anchor) / (7 * 24 * 60 * 60) % 2 == 0 ))
  '';
  dependencies = [
    "jellyfin.service"
    "sops-install-secrets.service"
  ];
in
{
  systemd.services.jellyfin-language-tags-refresh = {
    description = "Force a full refresh of Jellyfin language tags";
    requires = dependencies;
    after = dependencies;
    # The Sunday system switch can restart Jellyfin before the scan completes.
    before = [ "nixos-upgrade.service" ];
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

  systemd.timers.jellyfin-language-tags-refresh = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:00";
      Persistent = false;
    };
  };
}
