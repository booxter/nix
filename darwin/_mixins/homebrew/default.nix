{ ... }: {
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    casks = [
      "amethyst"
      "chatgpt"
      "todoist"
    ];
  };

  nix-homebrew = {
    enable = true;
    user = "ihrachyshka";
  };
}
