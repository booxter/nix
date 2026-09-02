{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  agents = config.host.hermesAgents;
  package = pkgs.hermes-agent;
  providerFor = agent: outputs.nixosConfigurations.${agent.providerHost}.config or null;
  unitName = name: "hermes-agent-${name}";
  userName = name: unitName name;
  hermesHome = agent: "${agent.stateDir}/.hermes";
  inputTarget = agent: name: "${agent.workingDirectory}/input/${name}";
  outputTarget = agent: name: "${agent.workingDirectory}/output/${name}";
  shellInitFor =
    name: agent:
    pkgs.writeText "hermes-agent-${name}-shell-init" ''
      export PATH=${
        lib.escapeShellArg (
          lib.makeBinPath (
            [
              package
              pkgs.bash
              pkgs.coreutils
            ]
            ++ agent.tools
          )
        )
      }:"$PATH"
    '';
  configFileFor =
    name: agent:
    (pkgs.formats.json { }).generate "hermes-agent-${name}.json" (
      lib.recursiveUpdate agent.settings {
        model = {
          default = agent.model;
          provider = "custom";
          base_url = "http://127.0.0.1:${toString agent.ollamaTunnelPort}/v1";
          context_length = agent.contextLength;
          ollama_num_ctx = agent.contextLength;
        };
        platform_toolsets.api_server = agent.toolsets ++ [ "no_mcp" ];
        terminal = {
          backend = "local";
          cwd = agent.workingDirectory;
          home_mode = "profile";
          shell_init_files = [ "${shellInitFor name agent}" ];
        };
      }
    );
  activationFor =
    name: agent:
    let
      home = hermesHome agent;
      apiEnvironment = "${home}/api-server.env";
      installDocuments = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          document: source:
          "install -o ${userName name} -g ${userName name} -m 0440 ${source} ${agent.workingDirectory}/${document}"
        ) agent.documents
      );
    in
    lib.stringAfter [ "users" ] ''
      install -d -o ${userName name} -g ${userName name} -m 0750 ${agent.stateDir}
      install -d -o ${userName name} -g ${userName name} -m 0750 ${home}
      install -d -o ${userName name} -g ${userName name} -m 0750 ${home}/home
      install -d -o ${userName name} -g ${userName name} -m 0750 ${home}/cron
      install -d -o ${userName name} -g ${userName name} -m 0750 ${home}/logs
      install -d -o ${userName name} -g ${userName name} -m 0750 ${home}/memories
      install -d -o ${userName name} -g ${userName name} -m 0750 ${home}/plugins
      install -d -o ${userName name} -g ${userName name} -m 0750 ${home}/sessions
      install -d -o ${userName name} -g ${userName name} -m 0750 ${agent.workingDirectory}
      install -d -o ${userName name} -g ${userName name} -m 0750 ${agent.workingDirectory}/input
      install -d -o ${userName name} -g ${userName name} -m 0750 ${agent.workingDirectory}/output
      ${lib.concatStringsSep "\n" (
        map (target: "install -d -o ${userName name} -g ${userName name} -m 0750 ${target}") (
          lib.mapAttrsToList (input: _: inputTarget agent input) agent.filesystem.inputs
        )
      )}
      ${lib.concatStringsSep "\n" (
        map (target: "install -d -o ${userName name} -g ${userName name} -m 0750 ${target}") (
          lib.mapAttrsToList (output: _: outputTarget agent output) agent.filesystem.outputs
        )
      )}
      install -o ${userName name} -g ${userName name} -m 0440 ${configFileFor name agent} ${home}/config.yaml
      install -o ${userName name} -g ${userName name} -m 0440 ${agent.soul} ${home}/SOUL.md
      touch ${home}/.managed
      chown ${userName name}:${userName name} ${home}/.managed
      chmod 0444 ${home}/.managed
      if [ ! -s ${apiEnvironment} ]; then
        umask 0077
        API_SERVER_KEY="$(${pkgs.coreutils}/bin/head -c 48 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w0)"
        ${pkgs.coreutils}/bin/printf 'API_SERVER_KEY=%s\n' "$API_SERVER_KEY" > ${apiEnvironment}
      fi
      chown ${userName name}:${userName name} ${apiEnvironment}
      chmod 0400 ${apiEnvironment}
      ${installDocuments}
    '';
  pkiClientFor =
    name: _agent:
    lib.nameValuePair (unitName name) {
      category = "internal";
      commonName = "${unitName name}.${config.networking.hostName}";
      materializations.default.restartUnits = [ "stunnel.service" ];
    };
  stunnelClientFor =
    name: agent:
    let
      provider = providerFor agent;
      serverName =
        if provider == null || provider.host.ollama == null then
          "invalid"
        else
          provider.host.web.services.ollama.internal.serverName;
      client = config.host.pki.clients.${unitName name}.materializations.default;
    in
    lib.nameValuePair (unitName name) {
      accept = "127.0.0.1:${toString agent.ollamaTunnelPort}";
      connect = "${serverName}:443";
      cert = client.certificatePath;
      key = client.keyPath;
      checkHost = serverName;
      sni = serverName;
      CAFile = "${config.host.pki.authority.rootCaCertificate}";
      verifyChain = true;
      OCSPaia = false;
    };
  serviceFor =
    name: agent:
    let
      unit = unitName name;
      user = userName name;
      home = hermesHome agent;
      inputPaths = builtins.attrValues agent.filesystem.inputs;
      outputPaths = builtins.attrValues agent.filesystem.outputs;
      requiredPaths = inputPaths ++ outputPaths;
    in
    lib.nameValuePair unit {
      description = "Hermes Agent (${name})";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      restartTriggers = [
        (configFileFor name agent)
        (shellInitFor name agent)
      ];
      unitConfig.RequiresMountsFor = requiredPaths;
      environment = {
        API_SERVER_ENABLED = "true";
        API_SERVER_HOST = "127.0.0.1";
        API_SERVER_MODEL_NAME = name;
        API_SERVER_PORT = toString agent.apiPort;
        HOME = agent.stateDir;
        HERMES_HOME = home;
        HERMES_MANAGED = "true";
      };
      path = [
        package
        pkgs.bash
        pkgs.coreutils
      ]
      ++ agent.tools;
      serviceConfig = {
        User = user;
        Group = user;
        WorkingDirectory = agent.workingDirectory;
        EnvironmentFile = "${home}/api-server.env";
        ExecStart = "${package}/bin/hermes gateway";
        Restart = "always";
        RestartSec = "10s";
        UMask = agent.umask;
        BindReadOnlyPaths = lib.mapAttrsToList (
          input: source: "${source}:${inputTarget agent input}"
        ) agent.filesystem.inputs;
        BindPaths = lib.mapAttrsToList (
          output: source: "${source}:${outputTarget agent output}"
        ) agent.filesystem.outputs;
        InaccessiblePaths = agent.filesystem.hidden;
        ReadWritePaths = [
          agent.stateDir
          agent.workingDirectory
        ]
        ++ outputPaths;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        ProcSubset = "pid";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        IPAddressDeny = "any";
        IPAddressAllow = [
          "127.0.0.0/8"
          "::1/128"
        ];
      };
    };
in
{
  config = lib.mkIf (agents != { }) {
    environment.systemPackages = [
      package
      pkgs.hermes-runs
    ];

    host.pki.clients = builtins.listToAttrs (lib.mapAttrsToList pkiClientFor agents);

    services.stunnel = {
      enable = true;
      logLevel = lib.mkDefault "warning";
      user = null;
      group = null;
      clients = builtins.listToAttrs (lib.mapAttrsToList stunnelClientFor agents);
    };

    system.activationScripts = lib.mapAttrs' (
      name: agent: lib.nameValuePair (unitName name) (activationFor name agent)
    ) agents;

    systemd.services = builtins.listToAttrs (lib.mapAttrsToList serviceFor agents) // {
      stunnel = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
      };
    };

    users.groups = lib.mapAttrs' (name: _agent: lib.nameValuePair (userName name) { }) agents;
    users.users = lib.mapAttrs' (
      name: agent:
      lib.nameValuePair (userName name) {
        isSystemUser = true;
        group = userName name;
        extraGroups = agent.supplementaryGroups;
        home = agent.stateDir;
        createHome = false;
      }
    ) agents;
  };
}
