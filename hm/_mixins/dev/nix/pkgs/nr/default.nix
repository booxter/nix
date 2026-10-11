{
  builders ? "",
  localBuilders ? "",
  remoteHost ? "frame",
  reviewDirectory ? "~/src/nixpkgs",
  lib,
  git,
  nixpkgs-reviewFull,
  openssh,
  python3,
  pythonRuffCheckHook,
  tmux,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "nr";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [ pythonPackages.pydantic ];

  # Integration tests exercise real tmux servers on private Unix sockets.
  __darwinAllowLocalNetworking = true;

  nativeCheckInputs = with pythonPackages; [
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
    git
    tmux
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${
      lib.makeBinPath [
        nixpkgs-reviewFull
        openssh
        git
        tmux
      ]
    }"
    "--set NR_BUILDERS ${lib.escapeShellArg builders}"
    "--set NR_LOCAL_BUILDERS ${lib.escapeShellArg localBuilders}"
    "--set-default NR_REMOTE_HOST ${lib.escapeShellArg remoteHost}"
    "--set-default NR_REVIEW_DIRECTORY ${lib.escapeShellArg reviewDirectory}"
  ];

  preCheck = ''
    mypy src/nr
  '';

  pythonImportsCheck = [ "nr" ];

  meta = {
    description = "Review a nixpkgs pull request using the fleet's remote builders";
    license = lib.licenses.mit;
    mainProgram = "nr";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
