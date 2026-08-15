{
  atomicFileWrites,
  lib,
  makeWrapper,
  python3,
  ruff,
  util-linux,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "disk-bay-exporter";
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
    mypy src/disk_bay_exporter
  '';

  pythonImportsCheck = [ "disk_bay_exporter" ];

  postFixup = ''
    wrapProgram "$out/bin/disk-bay-metrics" \
      --prefix PATH : ${lib.makeBinPath [ util-linux ]}
  '';

  meta = {
    description = "Export physical disk-bay mappings as Prometheus metrics";
    license = lib.licenses.mit;
    mainProgram = "disk-bay-metrics";
    platforms = lib.platforms.linux;
  };
}
