{
  lib,
  python3,
  pythonRuffCheckHook,
  makeWrapper,
  iproute2,
  atomicFileWrites,
}:
python3.pkgs.buildPythonApplication {
  pname = "cake-metrics";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ python3.pkgs.setuptools ];
  dependencies = [
    atomicFileWrites
    python3.pkgs.prometheus-client
    python3.pkgs.pydantic
  ];
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    python3.pkgs.mypy
    python3.pkgs.pytestCheckHook
    python3.pkgs.pytest-cov
    pythonRuffCheckHook
  ];
  preCheck = "mypy src/cake_metrics";
  pythonImportsCheck = [ "cake_metrics" ];
  postFixup = ''
    wrapProgram "$out/bin/cake-metrics" --prefix PATH : ${lib.makeBinPath [ iproute2 ]}
  '';
  meta = {
    description = "Collect CAKE queue and congestion-control state for Prometheus";
    license = lib.licenses.mit;
    mainProgram = "cake-metrics";
    platforms = lib.platforms.linux;
  };
}
