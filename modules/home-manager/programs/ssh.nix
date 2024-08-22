{
  enable = true;
  forwardAgent = true;
  addKeysToAgent = "yes";
  includes = [ "config.backup" "config.local" ];
  extraConfig = "SetEnv TERM=xterm-256color";
}
