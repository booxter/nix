{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  presetDefinitions = {
    personal = {
      roles.developer = {
        features = {
          dev.agents.codex.warmer.enable = true;
          containers.enable = true;
          shell.llm.enable = true;
          dev.scm = {
            identity = "personal";
            sendEmail.transport = "gmail";
          };
        };
        repositories.requests.preset = [ "dotfiles" ];
      };
      roles.workstation = {
        features = {
          containers = {
            enable = true;
            desktop.enable = true;
          };
          apps.email.account = "gmail";
        };
        hm = {
          gmailctl = {
            enable = true;
            warmer.enable = true;
          };
          thunderbird.enable = true;
        };
      };
    };
    nvidia = {
      roles.developer.features = {
        dev.attentionInbox.enable = true;
        dev.agents.codex = {
          usageStatus.enable = false;
          resetCredits.enable = false;
          workUsageStatus.enable = true;
        };
        dev.nvidia.enable = true;
        dev.scm = {
          identity = "nvidia";
          sendEmail.transport = "nvidia";
        };
      };
      roles.workstation = {
        features = {
          apps.email.account = "nvidia";
          apps.firefox.enable = false;
          apps.homerow.enable = false;
          apps.teams.enable = true;
        };
        hm.thunderbird.enable = true;
      };
    };
  };
  applyPresetDefaults = lib.mapAttrsRecursive (_: value: lib.mkOverride 900 value);
  userEnvironmentFragment = fragment: builtins.removeAttrs fragment [ "hm" ];
  mkPresetConfig =
    name: definition:
    lib.mkIf (cfg.preset == name) (
      lib.mkMerge (
        [ (applyPresetDefaults (definition.defaults or { })) ]
        ++ lib.mapAttrsToList (
          role: fragment:
          lib.mkIf cfg.roles.${role}.enable (applyPresetDefaults (userEnvironmentFragment fragment))
        ) (definition.roles or { })
      )
    );
  mkPresetHmConfig =
    name: definition:
    lib.mkIf (cfg.preset == name) (
      lib.mkMerge (
        lib.mapAttrsToList (
          role: fragment: lib.mkIf cfg.roles.${role}.enable (applyPresetDefaults (fragment.hm or { }))
        ) (definition.roles or { })
      )
    );
in
{
  options.host.userEnvironment.preset = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum (builtins.attrNames presetDefinitions));
    default = null;
    description = "Named fleet policy providing overridable user-environment feature defaults.";
  };
  config = {
    host.userEnvironment = lib.mkMerge (lib.mapAttrsToList mkPresetConfig presetDefinitions);
    home-manager.users.${config.host.username}.host.hm = lib.mkMerge (
      lib.mapAttrsToList mkPresetHmConfig presetDefinitions
    );
  };
}
