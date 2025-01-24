# TODO: darwin only
# TODO: confirm it still works
{ lib, pkgs, username ? "ihrachys", ... }: pkgs.writeScriptBin "clean-uri-handlers"
(let
    lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
    xargs = "${pkgs.findutils}/bin/xargs -d '\\n'";
    grep = "${lib.getExe pkgs.gnugrep}";
in ''
  # Unregister anything not in expected directories (nixstore and user apps)
  ${lsregister} -dump | ${grep} -oE '(/Users/${username}/.*\.app)' | grep -v '/Users/${username}/\(Applications\|Library\)' | ${xargs} ${lsregister} -f -u
  '')
