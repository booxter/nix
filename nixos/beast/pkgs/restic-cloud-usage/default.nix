{
  atomicFileWrites,
  lib,
  makeWrapper,
  python3,
  restic,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "restic-cloud-usage";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.b2sdk
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
    mypy src/restic_cloud_usage
  '';

  pythonImportsCheck = [ "restic_cloud_usage" ];

  postFixup = ''
    wrapProgram "$out/bin/restic-cloud-usage" \
      --prefix PATH : ${lib.makeBinPath [ restic ]}
    wrapProgram "$out/bin/restic-cloud-offload" \
      --prefix PATH : ${lib.makeBinPath [ restic ]}
  '';

  meta = {
    description = "Export B2 bucket and restic repository usage metrics";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "restic-cloud-usage";
    platforms = lib.platforms.linux;
  };
}
