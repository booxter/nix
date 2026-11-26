{
  config,
  lib,
  osConfig,
  ...
}:
let
  shared = import ../shared.nix { inherit config lib osConfig; };
in
{
  programs.opencode =
    lib.mkIf (config.host.hm.env.roles.developer && config.host.hm.dev.opencode.enable)
      {
        enable = true;
        context = ../context.md;
        skills = shared.skills;

        settings = {
          update = "disable";
          model = "deepseek/deepseek-flash";
          providers.deepseek.settings.apiKey = "{file:${osConfig.sops.secrets.deepseekApiKey.path}}";
        };
      };
}
