{
  atomicFileWrites,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
  # pystemd installs complete .pyi files but omits the PEP 561 marker. Fix
  # this in the upstream nixpkgs dependency so downstream mypy users do not
  # need import suppressions.
  typedPystemd = pythonPackages.pystemd.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      touch "$out/${python3.sitePackages}/pystemd/py.typed"
    '';
  });
in
pythonPackages.buildPythonApplication {
  pname = "backup-metrics";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.prometheus-client
    pythonPackages.pydantic
    typedPystemd
  ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/backup_metrics
  '';

  pythonImportsCheck = [ "backup_metrics" ];

  meta = {
    description = "Persist systemd backup outcomes as Prometheus metrics";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.linux;
  };
}
