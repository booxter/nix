{
  config,
  lib,
  pkgs,
  rommModel,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg;
  volumes = map (
    mount: "${mount.source}:${mount.target}:${if mount.readOnly then "ro" else "rw"}"
  ) model.containerMounts;
  commonContainer = {
    image = model.image;
    imageFile = model.imageFile;
    pull = "never";
    podman.user = cfg.user;
    environment = model.commonEnvironment;
    environmentFiles = [ config.sops.templates."romm.env".path ];
    inherit volumes;
    networks = [ "slirp4netns:allow_host_loopback=true" ];
    workdir = "/backend";
    extraOptions = [
      "--cap-drop=all"
      "--security-opt=no-new-privileges"
    ];
  };
  setupBefore = [
    "romm-web-assets.service"
    "mysql.service"
    "romm-db-init.service"
    "romm-valkey.service"
    "sops-install-secrets.service"
  ]
  ++ [ "romm-backup.service" ];
  runtimeAfter = setupBefore ++ [ "romm-setup.service" ];
  userUnits = [
    "user-runtime-dir@${toString model.uid}.service"
    "user@${toString model.uid}.service"
  ];
  runtimeUnits = userUnits ++ [ "network-online.target" ] ++ runtimeAfter;
  runtimeEnvironment = {
    HOME = cfg.stateDir;
    XDG_RUNTIME_DIR = "/run/user/${toString model.uid}";
  };
  serviceOverride = {
    path = [ pkgs.slirp4netns ];
    requires = runtimeAfter;
    wants = lib.mkForce runtimeUnits;
    after = lib.mkForce runtimeUnits;
    environment = runtimeEnvironment;
  };
in
{
  config = lib.mkIf (cfg != null && model.ready) {
    virtualisation = {
      podman.extraPackages = [ pkgs.slirp4netns ];
      oci-containers = {
        backend = "podman";
        containers = {
          romm-api = commonContainer // {
            ports = [ "127.0.0.1:${toString cfg.port}:${toString cfg.port}" ];
            entrypoint = "/src/.venv/bin/gunicorn";
            cmd = [
              "--bind"
              "0.0.0.0:${toString cfg.port}"
              "--forwarded-allow-ips"
              "*"
              "--worker-class"
              "uvicorn_worker.UvicornWorker"
              "--workers"
              "1"
              "--timeout"
              "300"
              "--keep-alive"
              "2"
              "--max-requests"
              "1000"
              "--max-requests-jitter"
              "100"
              "--worker-connections"
              "1000"
              "--error-logfile"
              "-"
              "main:app"
            ];
          };
          romm-worker = commonContainer // {
            entrypoint = "/src/.venv/bin/rq";
            cmd = [
              "worker"
              "--path"
              "/backend"
              "--url"
              "redis://10.0.2.2:${toString cfg.cache.port}/0"
              "--results-ttl"
              "86400"
              "--logging_level"
              "INFO"
              "high"
              "default"
              "low"
            ];
          };
          romm-scheduler = commonContainer // {
            environment = model.commonEnvironment // {
              RQ_REDIS_HOST = "10.0.2.2";
              RQ_REDIS_PORT = toString cfg.cache.port;
              RQ_REDIS_DB = "0";
              RQ_REDIS_SSL = "0";
            };
            entrypoint = "/src/.venv/bin/rqscheduler";
            cmd = [
              "--path"
              "/backend"
              "--pid"
              "/tmp/rq_scheduler.pid"
            ];
          };
          romm-watcher = commonContainer // {
            entrypoint = "/src/.venv/bin/watchfiles";
            # watchfiles accepts the child command as one argument; the
            # container itself is still executed without a shell wrapper.
            cmd = [
              "--target-type"
              "command"
              "/src/.venv/bin/python3 watcher.py"
              "/romm/library"
            ];
          };
        };
      };
    };

    systemd.services = {
      podman-romm-api = serviceOverride;
      podman-romm-worker = serviceOverride;
      podman-romm-scheduler = serviceOverride;
      podman-romm-watcher = serviceOverride;
    };
  };
}
