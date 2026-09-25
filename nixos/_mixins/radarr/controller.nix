{
  config,
  lib,
  ...
}:
let
  mkControllerService = import ../media-repair/controller-service.nix;
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    controller
    planner
    sabnzbd
    selectedDownloadClients
    transmission
    worker
    ;
  serviceName = "radarr-repair-controller";
  review = config.host.mediaRepair.review;
  reviewDirectory = "${review.stateDirectory}/radarr";
  killSwitchFile = "/run/radarr-repair-disable-apply";
  metricsFile = "${controller.metricsDirectory}/radarr-repair.prom";
  sabnzbdSecret = if sabnzbd == null then null else sabnzbd.authentication.secret;
  downloadClientArguments =
    lib.optionals (transmission != null) [
      "--transmission-url"
      transmission.endpoint
    ]
    ++ lib.optionals (sabnzbd != null) [
      "--sabnzbd-url"
      sabnzbd.endpoint
      "--sabnzbd-api-key-file"
      "%d/sabnzbd-api-key"
    ];
  downloadClientUnits = map (client: "${client.implementation}.service") selectedDownloadClients;
  downloadClientCredentials = lib.optionals (sabnzbdSecret != null) [
    "sabnzbd-api-key:${config.sops.secrets.${sabnzbdSecret}.path}"
  ];
  rootIDs = if worker == null then [ ] else builtins.attrNames worker.roots;
  rootPaths = if worker == null then [ ] else builtins.attrValues worker.roots;
  rootArguments = lib.concatMap (rootID: [
    "--worker-root"
    "${rootID}=${worker.roots.${rootID}}"
  ]) rootIDs;
  actionArguments = lib.concatMap (action: [
    "--allow-action"
    action
  ]) controller.apply.allowedActions;
  allowedDownloadClientArguments = lib.concatMap (client: [
    "--allow-download-client"
    client
  ]) controller.apply.allowedDownloadClients;
  modeArguments =
    if controller.apply.enable then
      [
        "run"
        "--apply"
        "--kill-switch-file"
        killSwitchFile
      ]
      ++ actionArguments
      ++ allowedDownloadClientArguments
      ++ lib.optionals controller.apply.finalizeStaleQueue [ "--finalize-stale-queue" ]
    else
      [ "shadow" ];
  plannerTimeoutSeconds = planner.planningTimeoutSeconds + 30;
  command = lib.escapeShellArgs (
    [
      (lib.getExe controller.package)
    ]
    ++ modeArguments
    ++ [
      "--radarr-url"
      "http://127.0.0.1:${toString config.services.radarr.settings.server.port}"
      "--radarr-api-key-file"
      "%d/radarr-api-key"
      "--worker-socket"
      worker.socketPath
      "--planner-socket"
      planner.socketPath
      "--state-directory"
      "/var/lib/${serviceName}"
      "--metrics-file"
      metricsFile
      "--stabilization"
      controller.stabilization
      "--planner-timeout"
      "${toString plannerTimeoutSeconds}s"
      "--worker-stage-timeout"
      "${toString (worker.joinTimeoutSeconds + 30)}s"
    ]
    ++ downloadClientArguments
    ++ lib.optionals review.enable [
      "--review-directory"
      reviewDirectory
    ]
    ++ rootArguments
  );
in
{
  config = lib.mkIf (controller != null && controller.enable) (
    lib.mkMerge [
      (mkControllerService {
        applicationService = "radarr.service";
        inherit
          command
          planner
          rootPaths
          serviceName
          worker
          ;
        credentials = [
          "radarr-api-key:${config.sops.secrets."radarr/apiKey".path}"
        ]
        ++ downloadClientCredentials;
        description =
          if controller.apply.enable then
            "Plan and apply permitted Radarr import repairs"
          else
            "Plan Radarr import repairs in shadow mode";
        interval = controller.interval;
        timerDescription = "Periodically run the Radarr repair controller";
        timeoutStopSec = "35s";
        extraRequiredUnits = downloadClientUnits;
        readWritePaths = [ controller.metricsDirectory ] ++ lib.optionals review.enable [ reviewDirectory ];
        supplementaryGroups = lib.optionals review.enable [ review.writerGroup ];
        wantedUnits = [ "network-online.target" ];
      })
      {
        assertions = [
          {
            assertion = !controller.apply.finalizeStaleQueue || controller.apply.enable;
            message = "Radarr stale queue finalization requires apply mode.";
          }
        ];

        systemd.tmpfiles.rules = [
          "d ${controller.metricsDirectory} 0755 ${serviceName} ${serviceName} - -"
        ];

        sops.secrets = lib.optionalAttrs (sabnzbdSecret != null) {
          ${sabnzbdSecret}.restartUnits = [ "${serviceName}.service" ];
        };
      }
    ]
  );
}
