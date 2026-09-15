{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  radarrOptions = import ../../nixos/_mixins/radarr/options.nix { inherit lib pkgs; };
  mediaRoot = "/var/lib/radarr-repair-test-media";
  emptyQueue = builtins.toJSON {
    page = 1;
    pageSize = 250;
    records = [ ];
    sortDirection = "ascending";
    sortKey = "added";
    totalRecords = 0;
  };
in
pkgs.testers.runNixOSTest {
  name = "radarr-repair-controller";

  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos/_mixins/downloads/default.nix
      ../../nixos/_mixins/radarr/assertions.nix
      ../../nixos/_mixins/radarr/controller.nix
      ../../nixos/_mixins/radarr/repair.nix
      ../../nixos/_mixins/radarr/worker.nix
      ./lib/sops.nix
    ];

    options.host.radarr = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { options = radarrOptions; });
      default = null;
    };
    options.host.storage.claims = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };

    config = {
      host.radarr.repair = {
        controller = {
          enable = true;
          downloadClients = [
            "transmission"
            "sabnzbd"
          ];
          apply = {
            enable = true;
            allowedActions = [ "manual_import_file_v1" ];
            allowedDownloadClients = [ "transmission" ];
          };
        };
        planner.enable = true;
        worker = {
          enable = true;
          roots."root:downloads" = mediaRoot;
        };
      };

      host.downloads.clients = {
        transmission = {
          kind = "torrent";
          implementation = "transmission";
          endpoint = "http://127.0.0.1:9091/transmission/rpc";
          authentication = {
            type = "none";
            secret = null;
          };
        };
        sabnzbd = {
          kind = "usenet";
          implementation = "sabnzbd";
          endpoint = "http://127.0.0.1:8080";
          authentication = {
            type = "api-key";
            secret = "sabnzbd/apiKey";
          };
        };
      };

      testSupport.sops.values = {
        "radarr/apiKey" = "test-radarr-key";
        "radarr-repair/openrouter-api-key" = "test-openrouter-key";
        "sabnzbd/apiKey" = "test-sabnzbd-key";
      };
      sops.secrets."radarr/apiKey" = { };
      sops.secrets."sabnzbd/apiKey" = { };

      users.groups.media = { };
      systemd.tmpfiles.rules = [ "d ${mediaRoot} 0750 root media -" ];

      services.nginx = {
        enable = true;
        virtualHosts.radarr-test = {
          listen = [
            {
              addr = "127.0.0.1";
              port = 7878;
            }
          ];
          locations."/api/v3/queue".extraConfig = ''
            default_type application/json;
            return 200 '${emptyQueue}';
          '';
        };
      };

      systemd.services = {
        radarr = {
          wantedBy = [ "multi-user.target" ];
          requires = [ "nginx.service" ];
          after = [ "nginx.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
            RemainAfterExit = true;
          };
        };
        transmission = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
            RemainAfterExit = true;
          };
        };
        sabnzbd = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
            RemainAfterExit = true;
          };
        };
      };
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("radarr-repair-controller.timer")
    machine.succeed("systemctl start radarr-repair-controller.service")
    metrics = machine.succeed(
        "cat /var/lib/prometheus-node-exporter-textfile/radarr-repair/radarr-repair.prom"
    )
    assert "host_observability_radarr_repair_shadow_run_success 1" in metrics
    assert 'host_observability_radarr_repair_shadow_cases{outcome="observed"} 0' in metrics
    assert "host_observability_radarr_repair_apply_run_success 1" in metrics
    assert "host_observability_radarr_repair_apply_disabled 0" in metrics
    assert 'host_observability_radarr_repair_apply_cases{outcome="selected"} 0' in metrics

    machine.succeed("touch /run/radarr-repair-disable-apply")
    machine.succeed("systemctl start radarr-repair-controller.service")
    metrics = machine.succeed(
        "cat /var/lib/prometheus-node-exporter-textfile/radarr-repair/radarr-repair.prom"
    )
    assert "host_observability_radarr_repair_apply_run_success 1" in metrics
    assert "host_observability_radarr_repair_apply_disabled 1" in metrics
  '';
}
