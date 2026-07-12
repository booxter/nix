{
  bats,
  git,
  lib,
  shellcheck,
  writeShellApplication,
}:
writeShellApplication {
  name = "sync-repo";
  runtimeInputs = [ git ];
  text = builtins.readFile ./sync-repo.sh;

  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [
      bats
      git
      shellcheck
    ];
  };
  checkPhase = ''
    runHook preCheck
    bash -n "$target"
    ${lib.getExe shellcheck} "$target"
    SYNC_REPO_BIN="$target" ${lib.getExe bats} --print-output-on-failure ${./sync-repo.bats}
    runHook postCheck
  '';

  meta = {
    description = "Synchronize a personal Git repository on demand";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "sync-repo";
  };
}
