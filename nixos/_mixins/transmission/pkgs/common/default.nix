{
  lib,
  python3,
  pythonRuffCheckHook,
}:

python3.pkgs.buildPythonPackage {
  pname = "transmission-common";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [
    python3.pkgs.setuptools
  ];

  nativeCheckInputs = [
    python3.pkgs.mypy
    pythonRuffCheckHook
  ];

  pythonRuffCheckPaths = [
    "transmission_common"
    "test_transmission.py"
  ];

  pythonImportsCheck = [
    "transmission_common.transmission"
  ];

  checkPhase = ''
    runHook preCheck
    mypy transmission_common
    python -m unittest discover -s . -p 'test_*.py'
    runHook postCheck
  '';

  meta = {
    description = "Shared Transmission RPC helpers for local service scripts";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
