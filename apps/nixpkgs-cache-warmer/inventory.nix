{
  excludePnamePatternsJson ? "[]",
  maintainer,
  nixpkgsSource,
  system,
}:
let
  source = builtins.toPath nixpkgsSource;
  pkgs = import source {
    localSystem = { inherit system; };
  };
  packages = import (source + "/maintainers/scripts/build.nix") {
    inherit maintainer system;
  };
  excludePnamePatterns = builtins.fromJSON excludePnamePatternsJson;
  excluded = pname: builtins.any (pattern: builtins.match pattern pname != null) excludePnamePatterns;
  eligible =
    pkg:
    let
      pname = pkg.pname or pkg.name;
    in
    !(pkg.meta.broken or false) && pkgs.lib.meta.availableOn { inherit system; } pkg && !excluded pname;
  toRecord = pkg: {
    drvPath = builtins.unsafeDiscardStringContext pkg.drvPath;
    name = pkg.name;
    pname = pkg.pname or pkg.name;
    outputs = builtins.map (
      output: builtins.unsafeDiscardStringContext pkg.${output}.outPath
    ) pkg.outputs;
  };
  recordsByDrvPath = builtins.listToAttrs (
    map (pkg: {
      name = builtins.unsafeDiscardStringContext pkg.drvPath;
      value = toRecord pkg;
    }) (builtins.filter eligible packages)
  );
in
builtins.attrValues recordsByDrvPath
