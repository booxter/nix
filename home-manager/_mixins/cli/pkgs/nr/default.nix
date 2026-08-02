{
  bash,
  bats,
  builders ? "",
  lib,
  nixpkgs-reviewFull,
  shellcheck,
  writeShellApplication,
}:
writeShellApplication {
  name = "nr";
  runtimeInputs = [ nixpkgs-reviewFull ];
  runtimeEnv.NR_BUILDERS = builders;
  text = builtins.readFile ./nr;

  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [
      bash
      bats
      shellcheck
    ];
  };
  checkPhase = ''
    runHook preCheck
    ${lib.getExe bash} -n "$target"
    ${lib.getExe shellcheck} "$target"
    NR_BIN=${./nr} ${lib.getExe bats} --print-output-on-failure ${./nr.bats}
    runHook postCheck
  '';

  meta = {
    description = "Review a nixpkgs pull request using the fleet's remote builders";
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "nr";
  };
}
