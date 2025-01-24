{
  programs.ssh = {
    enable = true;

    # agent forwarding to remotes
    forwardAgent = true;
    addKeysToAgent = "yes";

    includes = [
      # homebrew ssh that I use to access GSS doesn't read this directory by
      # default, for some reason
      "/etc/ssh/ssh_config"

      # local config
      "config.backup" # prior to home-manager activation
      "config.local" # whatever I may want to add manually
    ];

    # some servers have a problem with kitty terminfo, be conservative
    extraConfig = "SetEnv TERM=xterm-256color";
  };
}
