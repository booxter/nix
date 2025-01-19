{
  enable = true;
  forwardAgent = true;
  addKeysToAgent = "yes";
  includes = [
    # homebrew ssh doesn't read this directory by default, for some reason
    "/etc/ssh/ssh_config"
    # local config
    "config.backup"
    "config.local"
  ];
  extraConfig = "SetEnv TERM=xterm-256color";
}
