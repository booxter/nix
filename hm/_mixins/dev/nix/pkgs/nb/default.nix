{
  builders ? "",
  lib,
  nix-output-monitor,
  writeShellApplication,
}:
writeShellApplication {
  name = "nb";
  runtimeInputs = [ nix-output-monitor ];
  text = ''
    exec nom build ${
      lib.optionalString (builders != "") "--builders ${lib.escapeShellArg builders}"
    } "$@"
  '';

  meta = {
    description = "Build with nix-output-monitor using the nixpkgs builder pool";
    license = lib.licenses.mit;
    mainProgram = "nb";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
