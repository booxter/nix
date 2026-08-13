{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  instances = builtins.filter (instance: instance.apiRegistration != null) (
    builtins.attrValues model.instances
  );
  compact = lib.filterAttrs (_: value: value != null);
  policyFor =
    policy:
    if policy == null then
      null
    else
      compact {
        missing_enabled = policy.missing.enable;
        batch_size = policy.missing.batchSize;
        sleep_interval_mins = policy.missing.intervalMinutes;
        hourly_cap = policy.missing.hourlyCap;
        cooldown_days = policy.missing.cooldownDays;
        post_release_grace_hrs = policy.missing.postReleaseGraceHours;
        missing_hot_retry_window_hrs = policy.missing.hotRetryWindowHours;
        missing_hot_retry_interval_hrs = policy.missing.hotRetryIntervalHours;
        queue_limit = policy.missing.queueLimit;
        missing_search_mode = policy.missing.searchMode;
        cutoff_enabled = policy.cutoff.enable;
        cutoff_batch_size = policy.cutoff.batchSize;
        cutoff_cooldown_days = policy.cutoff.cooldownDays;
        cutoff_hourly_cap = policy.cutoff.hourlyCap;
        upgrade_enabled = policy.upgrades.enable;
        upgrade_batch_size = policy.upgrades.batchSize;
        upgrade_cooldown_days = policy.upgrades.cooldownDays;
        upgrade_hourly_cap = policy.upgrades.hourlyCap;
        upgrade_search_mode = policy.upgrades.searchMode;
        upgrade_series_window_size = policy.upgrades.contextWindowSize;
        allowed_time_window = policy.schedule.allowedTimeWindow;
        search_order = policy.schedule.order;
        tag_filter_include = policy.tags.include;
        tag_filter_exclude = policy.tags.exclude;
      };
  credentialName = instance: "api-${instance.name}";
  desiredFor =
    instance:
    let
      api = instance.apiRegistration;
    in
    {
      key = instance.name;
      displayName = instance.displayName;
      interface = api.interface;
      enabled = instance.enable;
      inherit (api) url;
      credential = {
        name = credentialName instance;
        inherit (api.authentication.apiKey) format field;
      };
      policy = policyFor instance.policy;
    };
  configuration = pkgs.writeText "houndarr-reconcile.json" (
    builtins.toJSON { instances = map desiredFor instances; }
  );
  apiUnits = lib.unique (
    builtins.filter (unit: unit != null) (map (instance: instance.apiRegistration.localUnit) instances)
  );
  loadCredentials = map (
    instance: "${credentialName instance}:${instance.apiRegistration.authentication.apiKey.source}"
  ) instances;
  command = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.toolsPackage "houndarr-reconcile")
    "--data-dir"
    cfg.stateDir
    "--config"
    configuration
  ];
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.houndarr-reconcile = {
      description = "Reconcile declarative Houndarr instances";
      requires = [ "nginx.service" ] ++ apiUnits;
      after = [ "nginx.service" ] ++ apiUnits;
      before = [ "houndarr.service" ];
      environment.SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = command;
        Restart = "on-failure";
        RestartSec = "2s";
        User = cfg.user;
        Group = cfg.group;
        LoadCredential = loadCredentials;
        UMask = "0077";
        CapabilityBoundingSet = "";
        IPAddressAllow = [
          "localhost"
        ]
        ++ lib.unique (builtins.concatMap (instance: instance.apiRegistration.allowedCidrs) instances);
        IPAddressDeny = "any";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
      unitConfig.RequiresMountsFor = cfg.stateDir;
    };

    systemd.paths = lib.listToAttrs (
      map (instance: {
        name = "houndarr-${instance.name}-api-credential";
        value = {
          wantedBy = [ "paths.target" ];
          pathConfig = {
            PathChanged = instance.apiRegistration.authentication.apiKey.source;
            Unit = "houndarr-reconcile.service";
          };
        };
      }) instances
    );
  };
}
