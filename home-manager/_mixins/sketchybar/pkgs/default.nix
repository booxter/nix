{
  alertmanager ? null,
  attentionInbox,
  codexTools,
  jellyfin ? null,
  pkgs,
  pluginColors,
}:
let
  inherit (pkgs) lib;
  pluginNames = [
    "aerospace"
    "alertmanager"
    "attention-inbox"
    "battery"
    "clock"
    "codex"
    "codex-work"
    "disk"
    "front_app"
    "github-status"
    "ip_address"
    "jellyfin"
    "network"
    "spotify"
    "stock"
    "volume"
  ];
  nativePluginNames = [
    "alertmanager"
    "disk"
    "github-status"
    "ip_address"
    "jellyfin"
  ];
  packagedPluginNames = nativePluginNames ++ [
    "attention-inbox"
    "codex"
    "codex-work"
  ];
  shellPluginNames = builtins.filter (name: !builtins.elem name packagedPluginNames) pluginNames;
  sketchybarTools = pkgs.callPackage ./sketchybar-tools { };
  runtimePath = lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.curl
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.sketchybar
  ];
  pluginEnvironments = {
    alertmanager = lib.optionalAttrs (alertmanager != null) {
      ALERTMANAGER_URL = alertmanager.url;
      ALERTMANAGER_CA_CERTIFICATE = alertmanager.caCertificate;
      ALERTMANAGER_CLIENT_CERTIFICATE = alertmanager.clientCertificate;
      ALERTMANAGER_CLIENT_KEY = alertmanager.clientKey;
    };
    "github-status" = {
      GITHUB_STATUS_URL = "https://www.githubstatus.com/api/v2/summary.json";
    };
    jellyfin = lib.optionalAttrs (jellyfin != null) {
      JELLYFIN_METRICS_URL = jellyfin.metricsUrl;
      JELLYFIN_CA_CERTIFICATE = jellyfin.caCertificate;
      JELLYFIN_CLIENT_CERTIFICATE = jellyfin.clientCertificate;
      JELLYFIN_CLIENT_KEY = jellyfin.clientKey;
    };
  };
  environmentArguments =
    environment:
    lib.concatStringsSep " " (
      lib.mapAttrsToList (
        name: value: "--set ${lib.escapeShellArg name} ${lib.escapeShellArg value}"
      ) environment
    );
  makePluginWrapper =
    name:
    let
      environment = pluginColors // (pluginEnvironments.${name} or { });
    in
    ''
      makeWrapper "$out/libexec/sketchybar/${name}.sh" "$out/bin/${name}" \
        --prefix PATH : ${lib.escapeShellArg runtimePath} \
      ${environmentArguments environment}
    '';
  makeBinaryPluginWrapper =
    name: package: executable:
    let
      environment =
        pluginColors
        // (pluginEnvironments.${name} or { })
        // {
          SKETCHYBAR_BIN = lib.getExe pkgs.sketchybar;
        };
    in
    ''
      makeWrapper ${lib.getExe' package executable} "$out/bin/${name}" \
        ${environmentArguments environment}
    '';
  makeNativePluginWrapper = name: executable: makeBinaryPluginWrapper name sketchybarTools executable;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "sketchybar-plugins";
  version = "1";

  src = ./plugins;

  nativeBuildInputs = [ pkgs.makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    for plugin in "$src"/*.sh; do
      ${lib.getExe pkgs.bash} -n "$plugin"
      ${lib.getExe pkgs.shellcheck} "$plugin"
    done
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec/sketchybar"
    install -m 0755 "$src"/*.sh "$out/libexec/sketchybar/"
    ${lib.concatMapStringsSep "\n" makePluginWrapper shellPluginNames}
    ${makeBinaryPluginWrapper "attention-inbox" attentionInbox "attention-inbox-sketchybar"}
    ${makeBinaryPluginWrapper "codex" codexTools "codex-sketchybar"}
    ${makeBinaryPluginWrapper "codex-work" codexTools "codex-work-sketchybar"}
    ${makeNativePluginWrapper "alertmanager" "sketchybar-alertmanager"}
    ${makeNativePluginWrapper "disk" "sketchybar-disk"}
    ${makeNativePluginWrapper "github-status" "sketchybar-github-status"}
    ${makeNativePluginWrapper "ip_address" "sketchybar-ip-address"}
    ${makeNativePluginWrapper "jellyfin" "sketchybar-jellyfin"}
    runHook postInstall
  '';

  passthru = { inherit pluginNames; };

  meta = {
    description = "Personal SketchyBar plugins";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.darwin;
  };
}
