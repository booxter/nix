{
  atomicFileWrites,
  lib,
  makeWrapper,
  python3,
  pythonRuffCheckHook,
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
    pythonRuffCheckHook
  ];

  preCheck = ''
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
    mainProgram = "storage-storcli-metrics";
    platforms = lib.platforms.linux;
  };
}
