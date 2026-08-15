{
  config,
  lib,
  utils,
  watchstateModel,
  ...
}:
let
  inherit (watchstateModel) cfg tools;
  systemUser = config.host.sso.applications.watchstate.bootstrapOwner;
  renderAuth = utils.escapeSystemdExecArgs [
    (lib.getExe' tools "watchstate-render-auth")
    "--system-user"
    systemUser
    "--password-file"
    config.sops.secrets."watchstate/system/password".path
    "--output"
    "/run/watchstate-auth/auth.env"
  ];
in
{
  config = lib.mkIf (cfg != null) {
    sops.secrets."watchstate/system/password" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [
        "watchstate-password-env.service"
        "podman-watchstate.service"
      ];
    };

    systemd.services.watchstate-password-env = {
      description = "Render the WatchState authentication environment";
      requires = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      before = [ "podman-watchstate.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "watchstate-auth";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        ExecStart = renderAuth;
      };
    };
  };
}
