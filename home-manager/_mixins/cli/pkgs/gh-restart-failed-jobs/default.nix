{
  bats,
  gh,
  jq,
  lib,
  shellcheck,
  writeShellApplication,
}:
writeShellApplication {
  name = "gh-restart-failed-jobs";
  runtimeInputs = [
    gh
    jq
  ];
  text = builtins.readFile ./gh-restart-failed-jobs.sh;

  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [
      bats
      jq
      shellcheck
    ];
  };
  checkPhase = ''
    runHook preCheck
    bash -n "$target"
    ${lib.getExe shellcheck} "$target"
    GH_RESTART_FAILED_JOBS_BIN=${./gh-restart-failed-jobs.sh} \
      ${lib.getExe bats} --print-output-on-failure ${./gh-restart-failed-jobs.bats}
    runHook postCheck
  '';

  meta = {
    description = "Restart failed GitHub Actions jobs for a pull request";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "gh-restart-failed-jobs";
  };
}
