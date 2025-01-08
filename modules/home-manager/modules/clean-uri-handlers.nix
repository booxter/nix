{ pkgs, username, ... }: pkgs.writeScriptBin "clean-uri-handlers"
(let
    lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
    xargs = "${pkgs.findutils}/bin/xargs -d '\\n'";
    grep = "${pkgs.gnugrep}/bin/grep";
in ''
  # Unregister anything not in expected directories (nixstore and user apps)
  ${lsregister} -dump | ${grep} -oE '(/Users/${username}/.*\.app)' | grep -v '/Users/${username}/\(Applications\|Library\)' | ${xargs} ${lsregister} -f -u
  '')
