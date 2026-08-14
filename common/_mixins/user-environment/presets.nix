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
        sendEmail.transport = "gmail";
        hm = {
          dev.act.enable = true;
          dev.codex = {
            enable = true;
            usage.warmer.enable = true;
          };
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
          numberedWorkspaces = if config.nixpkgs.hostPlatform.isDarwin then 4 else 6;
          firefox = {
            enable = true;
            search.provider = "degoog";
          };
          gmailctl = {
            enable = true;
            warmer.enable = true;
          };
          hyprland.enable = !config.nixpkgs.hostPlatform.isDarwin;
          kitty.enable = true;
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
          wireshark.enable = true;
        };
      };
    };
    nvidia = {
      defaults.hm = {
        fullName = "Ihar Hrachyshka";
        email = "${config.host.username}@nvidia.com";
      };
      roles.developer.sendEmail.transport = "nvidia";
      roles.developer.hm.dev = {
        act.enable = true;
        codex = {
          enable = true;
          usage.account = "corporate";
        };
        go.enable = true;
        k8s.enable = true;
        nvidia.enable = true;
      };
      roles.developer.hm.sketchybar.attentionInbox.enable = true;
      roles.developer.hm.docker.enable = true;
      roles.workstation = {
        homerow.enable = false;
        hm = {
          kitty.enable = true;
          matrix.enable = true;
          obsidian.enable = true;
          slack.enable = true;
          spotify = {
            enable = true;
            spicetify.enable = true;
          };
          teams.enable = true;
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
          wireshark.enable = true;
          zoom.enable = true;
        };
      };
    };
  };
  applyPresetDefaults = lib.mapAttrsRecursive (_: value: lib.mkOverride 900 value);
  userEnvironmentFragment = fragment: removeAttrs fragment [ "hm" ];
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
