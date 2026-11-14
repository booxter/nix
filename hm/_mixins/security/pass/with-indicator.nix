{
  auth-request,
  gnupg,
  indicator,
  lib,
  makeWrapper,
  pass,
  runCommand,
  symlinkJoin,
}:
let
  gpg = runCommand "pass-gpg" { nativeBuildInputs = [ makeWrapper ]; } ''
    mkdir -p "$out/bin"
    makeWrapper ${auth-request}/bin/pass-gpg "$out/bin/gpg" \
      --add-flags ${
        lib.escapeShellArg (
          lib.escapeShellArgs [
            "--gpg-program"
            "${gnupg}/bin/gpg"
            "--indicator"
            (lib.getExe indicator)
            "--label"
            "OpenPGP"
            "--"
          ]
        )
      }
    ln -s gpg "$out/bin/gpg2"
  '';
in
symlinkJoin {
  name = "pass-with-indicator";
  paths = [ pass ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    rm "$out/bin/pass"
    # pass appends its GnuPG dependency to PATH. Prepend this shim so an
    # existing user-profile gpg cannot bypass activity reporting.
    makeWrapper ${lib.getExe pass} "$out/bin/pass" --prefix PATH : ${gpg}/bin
  '';
  meta.mainProgram = "pass";
}
