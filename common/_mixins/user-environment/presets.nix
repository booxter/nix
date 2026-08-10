{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  presetDefinitions = {
    personal = {
      roles.developer = {
        features = {
          codex.warmer.enable = true;
          localAi.enable = true;
          scm = {
            identity = "personal";
            sendEmail.transport = "gmail";
          };
        };
        repositories.requests.preset = [ "dotfiles" ];
      };
      roles.workstation.features = {
        email = {
          account = "gmail";
          gmailctl.enable = true;
        };
        podmanDesktop.enable = true;
      };
    };
    nvidia = {
      defaults.features.podmanMachine.enable = false;
      roles.developer.features = {
        attentionInbox.enable = true;
        codex = {
          usageStatus.enable = false;
          resetCredits.enable = false;
          workUsageStatus.enable = true;
        };
        nvidiaDevelopment.enable = true;
        scm = {
          identity = "nvidia";
          sendEmail.transport = "nvidia";
        };
      };
      roles.workstation.features = {
        email = {
          account = "nvidia";
          gmailctl.enable = false;
        };
        firefox.enable = false;
        homerow.enable = false;
        microsoftTeams.enable = true;
      };
    };
  };
  applyPresetDefaults = lib.mapAttrsRecursive (_: value: lib.mkOverride 900 value);
  mkPresetConfig =
    name: definition:
    lib.mkIf (cfg.preset == name) (
      lib.mkMerge (
        [ (applyPresetDefaults (definition.defaults or { })) ]
        ++ lib.mapAttrsToList (
          role: fragment: lib.mkIf cfg.roles.${role}.enable (applyPresetDefaults fragment)
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
  config.host.userEnvironment = lib.mkMerge (lib.mapAttrsToList mkPresetConfig presetDefinitions);
}
