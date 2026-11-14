{
  lib,
  python3,
  pythonRuffCheckHook,
  atomicFileWrites,
}:
python3.pkgs.buildPythonApplication {
  pname = "memory-reclaim-metrics";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ python3.pkgs.setuptools ];
  dependencies = [
    atomicFileWrites
    python3.pkgs.prometheus-client
  ];
  nativeCheckInputs = [
    python3.pkgs.mypy
    python3.pkgs.pytestCheckHook
    python3.pkgs.pytest-cov
    pythonRuffCheckHook
  ];
  preCheck = "mypy src";
  pythonImportsCheck = [ "memory_reclaim_metrics" ];
  meta = {
    description = "Cgroup memory retention and pressure metrics for reclaim trials";
    mainProgram = "memory-reclaim-metrics";
    platforms = lib.platforms.linux;
    license = lib.licenses.mit;
  };
}
