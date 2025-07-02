{ ... }: {
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    casks = [
      "amethyst"
      "chatgpt"
      "element"
      "todoist"
    ];
  };

  nix-homebrew = {
    enable = true;
    user = "ihrachyshka";
  };
}
