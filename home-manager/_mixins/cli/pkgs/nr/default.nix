{
  builders ? "",
  lib,
  nixpkgs-reviewFull,
  writeShellApplication,
}:
writeShellApplication {
  name = "nr";
  runtimeInputs = [ nixpkgs-reviewFull ];
  runtimeEnv.NR_BUILDERS = builders;
  text = builtins.readFile ./nr;

  meta = {
    description = "Review a nixpkgs pull request using the fleet's remote builders";
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "nr";
  };
}
