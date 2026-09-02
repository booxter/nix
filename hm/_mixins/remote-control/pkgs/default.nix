{
  lib,
  openssh,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "remote-nixpkgs-runners";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeCheckInputs = with pythonPackages; [
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ openssh ]}"
  ];

  preCheck = ''
    mypy src/remote_nixpkgs
  '';

  pythonImportsCheck = [ "remote_nixpkgs" ];

  meta = {
    description = "Run remote Linux nixpkgs applications over X11 or Waypipe";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
