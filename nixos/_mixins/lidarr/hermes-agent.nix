{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.lidarr;
  enabled = cfg != null && cfg.agent.enable;
  configured = enabled && cfg.agent.providerHost != null && cfg.agent.model != null;
  mediaDir = config.host.storage.claims.media.mountPoint;
  outputDir = "${mediaDir}/.hermes-agent/lidarr-repair";
  filesystemInputs = {
    torrents = "${mediaDir}/torrents/lidarr";
  }
  // lib.optionalAttrs (config.host.sabnzbd != null) {
    usenet-manual = "${mediaDir}/usenet/manual";
  };
in
{
  config = lib.mkMerge [
    {
      assertions = lib.optionals enabled [
        {
          assertion = cfg.agent.providerHost != null;
          message = "host.lidarr.agent.providerHost is required when the Lidarr agent is enabled.";
        }
        {
          assertion = cfg.agent.model != null;
          message = "host.lidarr.agent.model is required when the Lidarr agent is enabled.";
        }
      ];
    }
    (lib.mkIf configured {
      host.hermesAgents.lidarr-repair = {
        inherit (cfg.agent) model providerHost;
        apiPort = 8643;
        ollamaTunnelPort = 11437;
        soul = ./hermes-agent/SOUL.md;
        documents."MEDIA_WORKFLOW.md" = ./hermes-agent/MEDIA_WORKFLOW.md;
        tools = [
          pkgs.ffmpeg
          pkgs.file
          pkgs.flac
          pkgs.mediainfo
          pkgs.unflac
          pkgs.unrar
        ];
        supplementaryGroups = [ "media" ];
        umask = "0007";
        toolsets = [
          "file"
          "memory"
          "terminal"
        ];
        settings.approvals.mode = "off";
        settings.auxiliary.title_generation.enabled = false;
        settings.model.max_tokens = 4096;
        filesystem = {
          hidden = [ mediaDir ];
          inputs = filesystemInputs;
          outputs.processed = outputDir;
        };
      };

      host.storage.claims.media = {
        directories.".hermes-agent/lidarr-repair" = {
          group = "media";
          mode = "2770";
        };
        attachments.hermes-agent-lidarr-repair = { };
      };
    })
  ];
}
