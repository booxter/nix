{
  username ? "ihrachyshka",
}:
let
  hostSpecs = import ./host-specs.nix { inherit username; };
  inherit (hostSpecs) toVmName;

  specToNixosWorkMap =
    spec:
    let
      isWork = spec.isWork or false;
    in
    if spec.type == "bm" then
      {
        ${spec.name} = isWork;
        ${"local-${spec.name}vm"} = isWork;
      }
    else if spec.type == "vm" then
      {
        ${"local-${toVmName spec.name}"} = isWork;
        ${"prox-${toVmName spec.name}"} = isWork;
      }
    else
      throw "Unsupported NixOS host spec type `${spec.type}`";
in
{
  darwin = builtins.mapAttrs (_: cfg: cfg.isWork or false) hostSpecs.darwinHosts;
  nixos = builtins.foldl' (acc: spec: acc // specToNixosWorkMap spec) { } hostSpecs.nixosHostSpecs;
}
