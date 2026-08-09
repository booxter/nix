{ facts, pkgs, ... }:
{
  package = import ../fact.nix { inherit facts pkgs; };
  description = "List fact libraries or print one as JSON.";
}
