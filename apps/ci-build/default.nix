{
  lib,
  attic-client,
  makeWrapper,
  nix,
  python3Packages,
  pythonRuffCheckHook,
}:
python3Packages.buildPythonApplication {
  pname = "ci-build";
  version = "0.1.0";
  pyproject = true;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./src
      ./tests
    ];
  };

  build-system = [ python3Packages.setuptools ];
  dependencies = [ python3Packages.pydantic ];
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = with python3Packages; [
    mypy
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
  ];
  preCheck = ''
    mypy src/ci_build
  '';
  pythonImportsCheck = [ "ci_build" ];
  postFixup = ''
    wrapProgram "$out/bin/ci-build" --prefix PATH : ${
      lib.makeBinPath [
        nix
        attic-client
      ]
    }
  '';
  meta = {
    description = "Build CI targets and publish only their output closures";
    mainProgram = "ci-build";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
