{
  config,
  hostSpec,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.gpu;
  isAmd = cfg != null && cfg.vendor == "amd";
  usesRocm = cfg != null && cfg.computeBackend == "rocm";
  metricsEnabled = isAmd && config.host.observability.enable;
  textfileDir = config.host.observability.nodeExporter.textfile.directory;
  metricsPackage = pkgs.callPackage ./amdgpu-metrics { };
in
{
  options.host.gpu = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          vendor = lib.mkOption {
            type = lib.types.enum [
              "amd"
              "intel"
            ];
            description = "GPU hardware vendor.";
          };

          computeBackend = lib.mkOption {
            type = with lib.types; nullOr (enum [ "rocm" ]);
            default = null;
            description = "GPU compute backend supported by this host.";
          };
        };
      }
    );
    default = hostSpec.hardware.gpu or null;
    readOnly = true;
    internal = true;
    description = "GPU capabilities declared by the host inventory.";
  };

  config = lib.mkMerge [
    {
      assertions = lib.optionals usesRocm [
        {
          assertion = isAmd;
          message = "ROCm compute requires an AMD GPU";
        }
      ];
    }
    (lib.mkIf isAmd {
      environment.systemPackages = with pkgs; [
        amdgpu_top
        radeontop
      ];
    })
    (lib.mkIf usesRocm {
      nixpkgs.config.rocmSupport = true;
      environment.systemPackages = with pkgs; [
        clinfo
        rocmPackages.rocm-smi
        rocmPackages.rocminfo
      ];
    })
    (lib.mkIf metricsEnabled {
      host.observability.nodeExporter.textfile.enable = true;

      systemd.services.amdgpu-metrics = {
        description = "Collect AMD GPU metrics for Prometheus";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe metricsPackage} --output ${textfileDir}/amdgpu.prom";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ textfileDir ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
          RestrictRealtime = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
        };
      };

      systemd.timers.amdgpu-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "30s";
          AccuracySec = "5s";
        };
      };

      systemd.tmpfiles.rules = [
        "d ${textfileDir} 0755 root root - -"
        "r ${textfileDir}/frame-amdgpu.prom - - - -"
      ];
    })
  ];
}
