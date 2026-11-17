{
  lib,
  makeWrapper,
  runCommand,
  ssh-device,
  identityFiles,
}:
runCommand "yubikey-agent" { nativeBuildInputs = [ makeWrapper ]; } ''
  mkdir -p "$out/bin"
  makeWrapper ${lib.getExe ssh-device} "$out/bin/yubikey-agent" \
    --add-flags ${lib.escapeShellArg (lib.escapeShellArgs ([ "load" ] ++ identityFiles))}
''
