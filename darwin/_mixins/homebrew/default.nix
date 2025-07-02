{ lib, isPrivate, ... }: {
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    casks = [
      "amethyst"
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
