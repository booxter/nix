{
  bats,
  git,
  lib,
  roots,
  shellcheck,
  writeShellApplication,
}:
writeShellApplication {
  name = "sync-git-mains";
  runtimeInputs = [ git ];
  text =
    lib.replaceStrings
      [ "@roots@" ]
      [
        (lib.concatMapStringsSep "\n  " lib.escapeShellArg roots)
      ]
      (builtins.readFile ./sync-git-mains.sh);

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
    SYNC_GIT_MAINS_BIN="$target" ${lib.getExe bats} --print-output-on-failure ${./sync-git-mains.bats}
    runHook postCheck
  '';

  meta = {
    description = "Discover and fast-forward local Git main branches from origin";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "sync-git-mains";
  };
}
