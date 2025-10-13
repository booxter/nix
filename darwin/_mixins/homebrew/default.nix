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
      "sf-symbols"
      "spotify" # spotify can't keep its shit together with hashes
      "todoist-app"
      "wireshark-chmodbpf"
    ];
  };

  nix-homebrew = {
    enable = true;
    user = username;
  };
}
