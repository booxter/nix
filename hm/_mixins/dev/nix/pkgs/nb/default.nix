{
  builders ? "",
  localBuilders ? "",
  lib,
  nix-output-monitor,
  writeShellApplication,
}:
writeShellApplication {
  name = "nb";
  runtimeInputs = [ nix-output-monitor ];
  text = ''
    local_only=
    arguments=()
    for argument in "$@"; do
      case "$argument" in
        -l|--local)
          local_only=1
          ;;
        *)
          arguments+=("$argument")
          ;;
      esac
    done

    if [[ -n "$local_only" ]]; then
      exec nom build --builders ${lib.escapeShellArg localBuilders} "''${arguments[@]}"
    fi

    exec nom build ${
      lib.optionalString (builders != "") "--builders ${lib.escapeShellArg builders}"
    } "''${arguments[@]}"
  '';

  meta = {
    description = "Build with nix-output-monitor using the nixpkgs builder pool";
    license = lib.licenses.mit;
    mainProgram = "nb";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
