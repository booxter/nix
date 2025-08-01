{ username, ... }: {
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    casks = [
      "amethyst"
      "wireshark-chmodbpf"
      "docker-desktop"
      "chatgpt"
      "element"
      "todoist"
    ];
  };

  nix-homebrew = {
    enable = true;
    user = username;
  };
}
