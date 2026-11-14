{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.memoryReclaim;
  policy = pkgs.writeText "oomd-reclaim.json" (
    builtins.toJSON {
      rulesets = [
        {
          name = "reclaim unmapped anonymous memory";
          silence-logs = "engine";
          detectors = [
            [
              "configured workloads"
              { name = "continue"; }
            ]
          ];
          actions = [
            {
              name = "senpai";
              args = {
                cgroup = lib.concatStringsSep "," cfg.cgroups;
                immediate_backoff = true;
                reclaim_unmapped_anon = true;
                limit_min_bytes = cfg.reserveMiB * 1024 * 1024;
                interval = cfg.intervalSeconds;
                max_probe = cfg.probeFraction;
                pressure_pct = cfg.pressurePercent;
                io_pressure_pct = cfg.pressurePercent;
                modulate_swappiness = false;
              };
            }
          ];
        }
      ];
    }
  );
  checkedPolicy = pkgs.runCommand "oomd-reclaim-policy" { nativeBuildInputs = [ cfg.package ]; } ''
    oomd --kmsg-override /dev/null --check-config ${policy}
    cp ${policy} "$out"
  '';
in
{
  options.host.memoryReclaim = {
    enable = lib.mkEnableOption "proactive reclaim of retained anonymous memory";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.oomd;
      description = "Meta oomd with reclaim_unmapped_anon support.";
    };
    cgroups = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-zA-Z0-9_.@/*-]+");
      default = [ ];
      description = "Cgroup paths relative to /sys/fs/cgroup; * matches names within a directory.";
    };
    reserveMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1024;
      description = "Reclaimable memory left in each cgroup, above its unreclaimable memory.";
    };
    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Minimum interval between probes with the one-second daemon tick.";
    };
    probeFraction = lib.mkOption {
      type = lib.types.numbers.between 0.0001 1;
      default = 0.01;
      description = "Fraction of reclaimable excess requested per probe; not a hard reclaim limit.";
    };
    pressurePercent = lib.mkOption {
      type = lib.types.numbers.between 0.0001 100;
      default = 0.1;
      description = "Memory or IO PSI percentage above which probes back off.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.cgroups != [ ]
          && lib.all (
            path:
            !(lib.hasPrefix "/" path)
            && !(lib.hasInfix "**" path)
            && !(builtins.elem ".." (lib.splitString "/" path))
          ) cfg.cgroups;
        message = "memoryReclaim requires relative cgroup targets without parent traversal or recursive globs";
      }
    ];

    systemd.services.oomd-reclaim = {
      description = "Reclaim retained anonymous memory with Senpai";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-sysctl.service" ];
      serviceConfig = {
        # Immediate backoff uses memory.reclaim, never persistent memory.high
        # limits. The policy contains no kill actions and leaves swappiness alone.
        # Disable the separate kill log; ordinary diagnostics go to stderr.
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe cfg.package)
          "--interval 1"
          "--config ${checkedPolicy}"
          "--runtime-dir /run/oomd-reclaim"
          "--kmsg-override /dev/null"
          "--senpai-threads 1"
          "--watchdog-timeout 30"
        ];
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "oomd-reclaim";
        MemoryLow = "64M";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectControlGroups = false;
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };
  };
}
