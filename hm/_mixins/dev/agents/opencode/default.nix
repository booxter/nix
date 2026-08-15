{
  config,
  lib,
  osConfig,
  ...
}:
{
  programs.opencode =
    lib.mkIf (config.host.hm.env.roles.developer && config.host.hm.dev.opencode.enable)
      {
        enable = true;
        settings = {
          autoupdate = false;
          model = "deepseek/deepseek-v4-pro";
          provider.deepseek.options.apiKey = "{file:${osConfig.sops.secrets.deepseekApiKey.path}}";
        };
      };
}
