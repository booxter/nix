{ lib, isDesktop, isPrivate, ... }: {
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    casks = lib.optionals isDesktop [
      "amethyst"
    ] ++ lib.optionals (!isPrivate) [
      "docker-desktop"
    ] ++ lib.optionals isPrivate [
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
