{
  facts,
  pkgs,
}:
{
  packages = {
    sops-tools = import ./package.nix { inherit facts pkgs; };
  };
}
