{
  inputs,
  outputs,
  ...
}:
{
  nixpkgs = {
    overlays = [
      inputs.nur.overlays.default
      outputs.overlays.additions
      outputs.overlays.modifications
    ];
    config = {
      allowUnfree = true;
    };
  };
}
