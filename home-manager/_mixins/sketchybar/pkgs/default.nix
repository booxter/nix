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
  goPluginNames = [
    "alertmanager"
    "disk"
    "github-status"
    "ip_address"
    "jellyfin"
    "network"
    "stock"
    "volume"
  ];
  packagedPluginNames = goPluginNames ++ [
    "attention-inbox"
    "battery"
    "codex"
    "codex-work"
    "spotify"
  ];
  shellPluginNames = builtins.filter (name: !builtins.elem name packagedPluginNames) pluginNames;
  sketchybarTools = pkgs.callPackage ./sketchybar-tools { };
  swiftApplets = pkgs.callPackage ./swift-applets { };
  runtimePath = lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
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
    stock = {
      STOCK_API_URL = "https://api.nasdaq.com/api/quote";
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
  makeGoPluginWrapper = name: executable: makeBinaryPluginWrapper name sketchybarTools executable;
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
    ${makeBinaryPluginWrapper "battery" swiftApplets "sketchybar-battery"}
    ${makeBinaryPluginWrapper "codex" codexTools "codex-sketchybar"}
    ${makeBinaryPluginWrapper "codex-work" codexTools "codex-work-sketchybar"}
    ${makeBinaryPluginWrapper "spotify" swiftApplets "sketchybar-spotify"}
    ${makeGoPluginWrapper "alertmanager" "sketchybar-alertmanager"}
    ${makeGoPluginWrapper "disk" "sketchybar-disk"}
    ${makeGoPluginWrapper "github-status" "sketchybar-github-status"}
    ${makeGoPluginWrapper "ip_address" "sketchybar-ip-address"}
    ${makeGoPluginWrapper "jellyfin" "sketchybar-jellyfin"}
    ${makeGoPluginWrapper "network" "sketchybar-network"}
    ${makeGoPluginWrapper "stock" "sketchybar-stock"}
    ${makeGoPluginWrapper "volume" "sketchybar-volume"}
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
