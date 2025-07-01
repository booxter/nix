# TODO: check module for homebrew?
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
}
