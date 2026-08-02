{
  alertmanager ? null,
  attentionInbox,
  codexUsageStatus,
  codexWorkUsageStatus,
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
  runtimePath = lib.makeBinPath [
    attentionInbox
    codexUsageStatus
    codexWorkUsageStatus
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
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "sketchybar-plugins";
  version = "1";

  src = ./plugins;

  nativeBuildInputs = [ pkgs.makeWrapper ];
  nativeCheckInputs = [
    pkgs.bash
    pkgs.bats
    pkgs.gawk
    pkgs.jq
    pkgs.shellcheck
  ];

  dontConfigure = true;
  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    for plugin in "$src"/*.sh; do
      ${lib.getExe pkgs.bash} -n "$plugin"
      ${lib.getExe pkgs.shellcheck} "$plugin"
    done
    SKETCHYBAR_PLUGIN_DIR="$src" \
      ${lib.getExe pkgs.bats} --print-output-on-failure ${./tests}/*.bats
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec/sketchybar"
    install -m 0755 "$src"/*.sh "$out/libexec/sketchybar/"
    ${lib.concatMapStringsSep "\n" makePluginWrapper pluginNames}
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
