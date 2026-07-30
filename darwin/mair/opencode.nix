{
  config,
  username,
  ...
}:
{
  sops.secrets.deepseekApiKey = {
    key = "deepseek/api_key";
    owner = username;
    group = "staff";
    mode = "0400";
  };

  home-manager.users.${username}.programs.opencode = {
    enable = true;
    settings = {
      model = "deepseek/deepseek-v4-pro";
      provider.deepseek.options.apiKey = "{file:${config.sops.secrets.deepseekApiKey.path}}";
    };
  };
}
