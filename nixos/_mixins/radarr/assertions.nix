{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    controller
    planner
    sabnzbd
    selectedDownloadClientNames
    selectedDownloadClients
    worker
    ;
  sabnzbdSecret = if sabnzbd == null then null else sabnzbd.authentication.secret;
  rootIDs = if worker == null then [ ] else builtins.attrNames worker.roots;
  rootPaths = if worker == null then [ ] else builtins.attrValues worker.roots;
  validRootID = rootID: builtins.match "^[a-z][a-z0-9_:-]{0,127}$" rootID != null;
  mediaWriteAllowed =
    controller != null
    && builtins.any (action: builtins.elem action controller.apply.allowedActions) [
      "join_parts_v1"
      "remux_bluray_v1"
    ];
in
{
  config.assertions =
    lib.optionals (controller != null && controller.enable) [
      {
        assertion = controller.downloadClients != [ ];
        message = "Radarr repair controller requires at least one download client.";
      }
      {
        assertion =
          builtins.length controller.downloadClients
          == builtins.length (lib.unique controller.downloadClients);
        message = "Radarr repair controller download clients must be unique.";
      }
      {
        assertion =
          builtins.length selectedDownloadClientNames == builtins.length controller.downloadClients;
        message = "Radarr repair controller download clients must be registered.";
      }
      {
        assertion = builtins.all (
          client:
          builtins.elem client.implementation [
            "transmission"
            "sabnzbd"
          ]
        ) selectedDownloadClients;
        message = "Radarr repair controller has an unsupported download client implementation.";
      }
      {
        assertion =
          builtins.length (map (client: client.implementation) selectedDownloadClients)
          == builtins.length (lib.unique (map (client: client.implementation) selectedDownloadClients));
        message = "Radarr repair controller download client implementations must be unique.";
      }
      {
        assertion = sabnzbd == null || (sabnzbd.authentication.type == "api-key" && sabnzbdSecret != null);
        message = "Radarr repair controller requires SABnzbd API-key authentication.";
      }
      {
        assertion = worker.enable;
        message = "Radarr repair controller requires the media probe worker.";
      }
      {
        assertion = planner.enable;
        message = "Radarr repair controller requires the repair planner.";
      }
      {
        assertion = !controller.apply.enable || controller.apply.allowedActions != [ ];
        message = "Radarr repair apply mode requires at least one allowed action.";
      }
      {
        assertion = !controller.apply.enable || controller.apply.allowedDownloadClients != [ ];
        message = "Radarr repair apply mode requires at least one allowed download client.";
      }
      {
        assertion = controller.apply.enable || controller.apply.allowedActions == [ ];
        message = "Radarr repair actions can be allowed only when apply mode is enabled.";
      }
      {
        assertion = controller.apply.enable || controller.apply.allowedDownloadClients == [ ];
        message = "Radarr repair download clients can be allowed only when apply mode is enabled.";
      }
      {
        assertion = builtins.all (
          name: builtins.elem name controller.downloadClients
        ) controller.apply.allowedDownloadClients;
        message = "Radarr repair can apply only configured download clients.";
      }
      {
        assertion =
          builtins.length controller.apply.allowedActions
          == builtins.length (lib.unique controller.apply.allowedActions);
        message = "Radarr repair allowed actions must be unique.";
      }
      {
        assertion =
          builtins.length controller.apply.allowedDownloadClients
          == builtins.length (lib.unique controller.apply.allowedDownloadClients);
        message = "Radarr repair allowed download clients must be unique.";
      }
      {
        assertion = !mediaWriteAllowed || worker.writableRoots != [ ];
        message = "Automatic media repairs require a writable worker root.";
      }
    ]
    ++ lib.optionals (planner != null && planner.enable) [
      {
        assertion = planner.planningTimeoutSeconds > 2 * planner.attemptTimeoutSeconds;
        message = "Radarr repair planning timeout must cover both model attempts.";
      }
    ]
    ++ lib.optionals (worker != null && worker.enable) [
      {
        assertion = worker.roots != { };
        message = "Radarr repair worker requires at least one media root.";
      }
      {
        assertion = builtins.all validRootID rootIDs;
        message = "Radarr repair worker root IDs must be valid opaque identifiers.";
      }
      {
        assertion = builtins.length rootPaths == builtins.length (lib.unique rootPaths);
        message = "Radarr repair worker root paths must be unique.";
      }
      {
        assertion = builtins.all (path: builtins.dirOf path != path) rootPaths;
        message = "Radarr repair worker cannot expose the filesystem root.";
      }
      {
        assertion =
          builtins.length worker.writableRoots == builtins.length (lib.unique worker.writableRoots);
        message = "Radarr repair worker writable root identifiers must be unique.";
      }
      {
        assertion = builtins.all (rootID: builtins.hasAttr rootID worker.roots) worker.writableRoots;
        message = "Radarr repair worker writable roots must name configured worker roots.";
      }
    ];
}
