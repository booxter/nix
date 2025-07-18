{
  programs.ssh = {
    enable = true;

    # agent forwarding to remotes
    forwardAgent = true;
    addKeysToAgent = "yes";

    includes = [
      # local config
      "config.backup" # prior to home-manager activation
      "config.local" # whatever I may want to add manually
      "~/.ssh/config.d/*"
    ];

    # some servers have a problem with kitty terminfo, be conservative
    extraConfig = "SetEnv TERM=xterm-256color";
  };
}
