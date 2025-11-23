{
  inputs,
  ...
}:
{
  nixpkgs.overlays = [
    (
      final: prev:
      let
        getPkgs =
          np:
          import np {
            inherit (prev) system;
          };
        pkgs = getPkgs inputs.nixpkgs-ff-lto;
      in
      {
        #inherit (pkgs) thunderbird-unwrapped firefox-unwrapped;
      }
    )
  ];

}
