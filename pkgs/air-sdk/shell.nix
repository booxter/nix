let
  pkgs = import <nixpkgs> { };
  air-sdk = ps: ps.callPackage ./. { };
  python-with-my-packages = pkgs.python3.withPackages (ps: [
    (air-sdk ps)
  ]);
in
pkgs.mkShell {
  packages = [
    python-with-my-packages
  ];
}
