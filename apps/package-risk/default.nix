{
  lib,
  makeWrapper,
  nix,
  python3,
  pythonRuffCheckHook,
  vulnix,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "package-risk";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./metadata.nix
      ./inventory.nix
      ./pyproject.toml
      ./src
      ./tests
    ];
  };

  build-system = [ pythonPackages.setuptools ];
  dependencies = with pythonPackages; [
    httpx
    pydantic
    pygithub
    requests
    univers
  ];

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonPackages.types-requests
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/package_risk
  '';

  pythonImportsCheck = [ "package_risk" ];

  postFixup = ''
    wrapProgram "$out/bin/risk" \
      --prefix PATH : ${lib.makeBinPath [ nix ]} \
      --set PACKAGE_RISK_INVENTORY_NIX ${./inventory.nix} \
      --set PACKAGE_RISK_METADATA_NIX ${./metadata.nix} \
      --set PACKAGE_RISK_VULNIX ${lib.getExe vulnix}
  '';

  meta = {
    description = "Report maintainer and vulnerability risks in Nix configuration closures";
    license = lib.licenses.mit;
    mainProgram = "risk";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
