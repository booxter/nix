{
  lib,
  python3,
}:

python3.pkgs.buildPythonPackage {
  pname = "transmission-common";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [
    python3.pkgs.setuptools
  ];

  pythonImportsCheck = [
    "transmission_common.transmission"
  ];

  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s . -p 'test_*.py'
    runHook postCheck
  '';

  meta = {
    description = "Shared Transmission RPC helpers for local service scripts";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.unix;
  };
}
