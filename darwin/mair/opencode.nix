{
  config,
  ...
}:
let
  username = config.host.username;
in
{
  sops.secrets.deepseekApiKey = {
    key = "deepseek/api_key";
    owner = username;
    group = "staff";
    mode = "0400";
  };

  home-manager.users.${username}.host.hm.dev.opencode.enable = true;
}
