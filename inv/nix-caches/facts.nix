{
  lanDomain,
  readPublicKey,
}:
let
  urlWithPriority = url: priority: "${url}?priority=${toString priority}";
  homeUrl = "https://nix-cache.${lanDomain}/default";
  flakehubUrl = "https://cache.flakehub.com";
in
{
  nixos = {
    url = "https://cache.nixos.org/";
    key = readPublicKey ../../public-keys/nix-cache/nixos.pub;
  };
  home = {
    url = homeUrl;
    key = readPublicKey ../../public-keys/nix-cache/home.pub;
    defaultUrl = urlWithPriority homeUrl 30;
    lanUrl = urlWithPriority homeUrl 10;
    vpnUrl = urlWithPriority homeUrl 30;
  };
  flakehub = {
    url = flakehubUrl;
    lanUrl = urlWithPriority flakehubUrl 30;
    vpnUrl = urlWithPriority flakehubUrl 10;
  };
}
