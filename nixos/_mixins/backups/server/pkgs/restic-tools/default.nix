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
  pname = "restic-tools";
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
    mypy src/restic_tools
  '';

  pythonImportsCheck = [ "restic_tools" ];

  postFixup = ''
    wrapProgram "$out/bin/restic-cloud-usage" \
      --prefix PATH : ${lib.makeBinPath [ restic ]}
    wrapProgram "$out/bin/restic-cloud-offload" \
      --prefix PATH : ${lib.makeBinPath [ restic ]}
  '';

  meta = {
    description = "Restic backup utilities: cloud offload and B2 usage metrics";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "restic-cloud-usage";
    platforms = lib.platforms.linux;
  };
}
