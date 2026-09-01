{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.radarr;
  enabled = cfg != null && cfg.agent.enable;
  configured = enabled && cfg.agent.providerHost != null && cfg.agent.model != null;
  mediaDir = config.host.storage.claims.media.mountPoint;
  outputDir = "${mediaDir}/.hermes-agent/radarr-repair";
  filesystemInputs = {
    torrents = "${mediaDir}/torrents/radarr";
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
          message = "host.radarr.agent.providerHost is required when the Radarr agent is enabled.";
        }
        {
          assertion = cfg.agent.model != null;
          message = "host.radarr.agent.model is required when the Radarr agent is enabled.";
        }
      ];
    }
    (lib.mkIf configured {
      host.hermesAgents.radarr-repair = {
        inherit (cfg.agent) model providerHost;
        apiPort = 8642;
        ollamaTunnelPort = 11436;
        soul = ./hermes-agent/SOUL.md;
        documents."MEDIA_WORKFLOW.md" = ./hermes-agent/MEDIA_WORKFLOW.md;
        tools = [
          pkgs.ffmpeg
          pkgs.file
          pkgs.join-media-parts
          pkgs.mediainfo
        ];
        supplementaryGroups = [ "media" ];
        # Share generated repairs through the setgid media output directory.
        umask = "0007";
        toolsets = [
          "file"
          "memory"
          "terminal"
        ];
        settings.approvals.mode = "off";
        settings.auxiliary.title_generation.enabled = false;
        filesystem = {
          hidden = [ mediaDir ];
          inputs = filesystemInputs;
          outputs.processed = outputDir;
        };
      };

      host.storage.claims.media = {
        directories.".hermes-agent/radarr-repair" = {
          group = "media";
          mode = "2770";
        };
        attachments.hermes-agent-radarr-repair = { };
      };
    })
  ];
}
