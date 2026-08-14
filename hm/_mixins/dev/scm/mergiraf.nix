{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf (config.host.hm.userEnvironment.preset != null) {
  programs.git.settings = {
    merge.mergiraf = {
      name = "mergiraf";
      driver = "mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P";
    };
    core.attributesfile = "${pkgs.writeText "gitattributes" ''
      *.java merge=mergiraf
      *.rs merge=mergiraf
      *.go merge=mergiraf
      *.js merge=mergiraf
      *.jsx merge=mergiraf
      *.json merge=mergiraf
      *.yml merge=mergiraf
      *.yaml merge=mergiraf
      *.html merge=mergiraf
      *.htm merge=mergiraf
      *.xhtml merge=mergiraf
      *.xml merge=mergiraf
      *.c merge=mergiraf
      *.cc merge=mergiraf
      *.h merge=mergiraf
      *.cpp merge=mergiraf
      *.hpp merge=mergiraf
      *.cs merge=mergiraf
      *.dart merge=mergiraf
    ''}";
  };

  home.packages = [ pkgs.mergiraf ];
}
