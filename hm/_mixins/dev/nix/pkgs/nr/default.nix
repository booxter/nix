{
  builders ? "",
  lib,
  nixpkgs-reviewFull,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "nr";
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
    "--prefix PATH : ${lib.makeBinPath [ nixpkgs-reviewFull ]}"
    "--set NR_BUILDERS ${lib.escapeShellArg builders}"
  ];

  preCheck = ''
    mypy src/nr
  '';

  pythonImportsCheck = [ "nr" ];

  meta = {
    description = "Review a nixpkgs pull request using the fleet's remote builders";
    license = lib.licenses.mit;
    mainProgram = "nr";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
