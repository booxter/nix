{
  config,
  lib,
  ...
}:
let
  mkControllerService = import ../media-repair/controller-service.nix;
  lidarr = config.host.lidarr;
  controller = if lidarr == null then null else lidarr.repair.controller;
  planner = config.host.mediaRepair.planner;
  worker = config.host.mediaRepair.worker;
  review = config.host.mediaRepair.review;
  serviceName = "lidarr-repair-controller";
  killSwitchFile = "/run/lidarr-repair-disable-apply";
  rootIDs = builtins.attrNames worker.roots;
  rootPaths = builtins.attrValues worker.roots;
  rootArguments = lib.concatMap (rootID: [
    "--worker-root"
    "${rootID}=${worker.roots.${rootID}}"
  ]) rootIDs;
  actionArguments = lib.concatMap (action: [
    "--allow-action"
    action
  ]) controller.apply.allowedActions;
  sourceArguments = lib.concatMap (source: [
    "--allow-source"
    source
  ]) controller.apply.allowedSources;
  modeArguments =
    if controller.apply.enable then
      [
        "--apply"
        "--kill-switch-file"
        killSwitchFile
      ]
      ++ actionArguments
      ++ sourceArguments
      ++ lib.optionals controller.apply.finalizeStaleQueue [ "--finalize-stale-queue" ]
    else
      [ ];
  reviewDirectory = "${review.stateDirectory}/lidarr";
  command =
    if controller == null then
      ""
    else
      lib.escapeShellArgs (
        [
          (lib.getExe controller.package)
          "--lidarr-url"
          "http://127.0.0.1:${toString config.services.lidarr.settings.server.port}"
          "--lidarr-api-key-file"
          "%d/lidarr-api-key"
          "--worker-socket"
          worker.socketPath
          "--planner-socket"
          planner.socketPath
          "--state-directory"
          "/var/lib/${serviceName}"
          "--request-timeout"
          "${toString controller.requestTimeoutSeconds}s"
          "--worker-stage-timeout"
          "${toString (worker.joinTimeoutSeconds + 30)}s"
          "--planner-timeout"
          "${toString (planner.planningTimeoutSeconds + 30)}s"
        ]
        ++ modeArguments
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
        applicationService = "lidarr.service";
        inherit
          command
          planner
          rootPaths
          serviceName
          worker
          ;
        credentials = [
          "lidarr-api-key:${config.sops.secrets."lidarr/apiKey".path}"
        ];
        description =
          if controller.apply.enable then
            "Plan and apply permitted Lidarr import repairs"
          else
            "Plan Lidarr import repairs in shadow mode";
        interval = controller.interval;
        timerDescription = "Periodically run the Lidarr repair controller";
        timeoutStopSec = "10s";
        readWritePaths = lib.optionals review.enable [ reviewDirectory ];
        supplementaryGroups = lib.optionals review.enable [ review.writerGroup ];
      })
      {
        assertions = [
          {
            assertion = worker.enable && planner.enable && worker.roots != { };
            message = "Lidarr repair requires the shared media worker and planner with roots.";
          }
          {
            assertion = !controller.apply.enable || controller.apply.allowedActions != [ ];
            message = "Lidarr repair apply mode requires at least one allowed action.";
          }
          {
            assertion = !controller.apply.enable || controller.apply.allowedSources != [ ];
            message = "Lidarr repair apply mode requires at least one allowed source.";
          }
          {
            assertion = !controller.apply.finalizeStaleQueue || controller.apply.enable;
            message = "Lidarr stale queue finalization requires apply mode.";
          }
          {
            assertion =
              controller.apply.enable
              || (controller.apply.allowedActions == [ ] && controller.apply.allowedSources == [ ]);
            message = "Lidarr repair actions and sources can be allowed only in apply mode.";
          }
          {
            assertion =
              builtins.length controller.apply.allowedActions
              == builtins.length (lib.unique controller.apply.allowedActions);
            message = "Lidarr repair allowed actions must be unique.";
          }
          {
            assertion =
              builtins.length controller.apply.allowedSources
              == builtins.length (lib.unique controller.apply.allowedSources);
            message = "Lidarr repair allowed sources must be unique.";
          }
        ];
      }
    ]
  );
}
