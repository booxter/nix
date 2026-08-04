{
  atomicFileWrites,
  lib,
  makeWrapper,
  python3,
  ruff,
  storcli,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "beast-storage-observability";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.prometheus-client
    pythonPackages.pydantic
  ];

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/beast_storage_observability
  '';

  pythonImportsCheck = [ "beast_storage_observability" ];

  postFixup = ''
    wrapProgram "$out/bin/beast-hba-metrics" \
      --prefix PATH : ${lib.makeBinPath [ storcli ]}
  '';

  meta = {
    description = "Typed Prometheus storage collectors for beast";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "beast-hba-metrics";
    platforms = lib.platforms.linux;
  };
}
