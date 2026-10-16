{
  config,
  lib,
  ...
}:
lib.mkIf config.host.hm.env.roles.developer {
  programs.jujutsu = {
    enable = true;
    settings.user = {
      name = config.host.hm.fullName;
      email = config.host.hm.email;
    };
  };
}
