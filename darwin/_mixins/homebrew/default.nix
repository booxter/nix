{ username, ... }:
{
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    casks = [
      "chatgpt"
      "docker-desktop"
      "element"
      "openvpn-connect"
      "todoist"
      "wireshark-chmodbpf"
    ];
  };

  nix-homebrew = {
    enable = true;
    user = username;
  };
}
