{
  atomicFileWrites,
  lib,
  makeWrapper,
  python3,
  ruff,
  storcli,
  util-linux,
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
    wrapProgram "$out/bin/storage-hba-metrics" \
      --prefix PATH : ${lib.makeBinPath [ storcli ]}
    wrapProgram "$out/bin/storage-disk-bay-metrics" \
      --prefix PATH : ${lib.makeBinPath [ util-linux ]}
  '';

  meta = {
    description = "Typed Prometheus storage collectors";
    license = lib.licenses.mit;
    mainProgram = "storage-hba-metrics";
    platforms = lib.platforms.linux;
  };
}
