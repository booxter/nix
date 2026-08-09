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
  pname = "storage-observability";
  version = "0.2.0";
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
    mypy src/storage_observability
  '';

  pythonImportsCheck = [ "storage_observability" ];

  postFixup = ''
    wrapProgram "$out/bin/storage-storcli-metrics" \
      --prefix PATH : ${lib.makeBinPath [ storcli ]}
  '';

  meta = {
    description = "Typed Prometheus collectors for Linux storage hardware";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "storage-storcli-metrics";
    platforms = lib.platforms.linux;
  };
}
