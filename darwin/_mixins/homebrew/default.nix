# TODO: check module for homebrew?
{ ... }: {
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    brews = [
      "openssh" # it supports gss
    ];
    casks = [
      "amethyst"
      "chatgpt"
      "todoist"
    ];
  };
}
