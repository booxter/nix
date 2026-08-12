{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  presetDefinitions = {
    personal = {
      defaults.hm = {
        fullName = "Ihar Hrachyshka";
        email = "ihar.hrachyshka@gmail.com";
      };
      roles.developer = {
        features = {
          dev.agents.codex.warmer.enable = true;
          dev.scm.sendEmail.transport = "gmail";
        };
        hm = {
          dev.act.enable = true;
          dev.codex.enable = true;
          dev.go.enable = true;
          podman = {
            enable = true;
          };
          ramalama.enable = true;
        };
        repositories.requests.preset = [ "dotfiles" ];
      };
      roles.workstation = {
        hm = {
          firefox.enable = true;
          gmailctl = {
            enable = true;
            warmer.enable = true;
          };
          matrix.enable = true;
          obsidian.enable = true;
          podman = {
            enable = true;
            desktop.enable = true;
          };
          spotify = {
            enable = true;
            spicetify.enable = true;
          };
          telegram.enable = true;
          thunderbird = {
            enable = true;
            account = {
              flavor = "gmail.com";
              imapAuthentication = "oauth2";
              smtp = {
                server = "smtp.gmail.com";
                authentication = "oauth2";
              };
            };
          };
        };
      };
    };
    nvidia = {
      defaults.hm = {
        fullName = "Ihar Hrachyshka";
        email = "${config.host.username}@nvidia.com";
      };
      roles.developer.features = {
        dev.attentionInbox.enable = true;
        dev.agents.codex = {
          usageStatus.enable = false;
          workUsageStatus.enable = true;
        };
        dev.nvidia.enable = true;
        dev.scm.sendEmail.transport = "nvidia";
      };
      roles.developer.hm.dev = {
        act.enable = true;
        codex.enable = true;
        go.enable = true;
        k8s.enable = true;
      };
      roles.developer.hm.docker.enable = true;
      roles.workstation = {
        features = {
          apps.homerow.enable = false;
          apps.teams.enable = true;
        };
        hm = {
          matrix.enable = true;
          obsidian.enable = true;
          spotify = {
            enable = true;
            spicetify.enable = true;
          };
          telegram.enable = true;
          thunderbird = {
            enable = true;
            account = {
              flavor = "outlook.office365.com";
              imapAuthentication = "oauth2";
              smtp = {
                server = "mail.nvidia.com";
                authentication = "password";
              };
            };
          };
        };
      };
    };
  };
  applyPresetDefaults = lib.mapAttrsRecursive (_: value: lib.mkOverride 900 value);
  userEnvironmentFragment = fragment: builtins.removeAttrs fragment [ "hm" ];
  mkPresetConfig =
    name: definition:
    lib.mkIf (cfg.preset == name) (
      lib.mkMerge (
        [ (applyPresetDefaults (userEnvironmentFragment (definition.defaults or { }))) ]
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
        [ (applyPresetDefaults (definition.defaults.hm or { })) ]
        ++ lib.mapAttrsToList (
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
