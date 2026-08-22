{
  excludePnamePatternsJson ? "[]",
  includePnamePatternsJson ? "[]",
  maintainer,
  nixpkgsSource,
  output ? "records",
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
  includePnamePatterns = builtins.fromJSON includePnamePatternsJson;
  excluded = pname: builtins.any (pattern: builtins.match pattern pname != null) excludePnamePatterns;
  included =
    pname:
    includePnamePatterns == [ ]
    || builtins.any (pattern: builtins.match pattern pname != null) includePnamePatterns;
  eligible =
    pkg:
    let
      pname = pkg.pname or pkg.name;
    in
    !(pkg.meta.broken or false)
    && pkgs.lib.meta.availableOn { inherit system; } pkg
    && included pname
    && !excluded pname;
  toRecord = pkg: {
    drvPath = builtins.unsafeDiscardStringContext pkg.drvPath;
    name = pkg.name;
    pname = pkg.pname or pkg.name;
    outputs = builtins.map (
      output: builtins.unsafeDiscardStringContext pkg.${output}.outPath
    ) pkg.outputs;
  };
  packagesByDrvPath = builtins.listToAttrs (
    map (pkg: {
      name = builtins.unsafeDiscardStringContext pkg.drvPath;
      value = pkg;
    }) (builtins.filter eligible packages)
  );
  selectedPackages = builtins.attrValues packagesByDrvPath;
in
if output == "packages" then map (pkg: pkg) selectedPackages else map toRecord selectedPackages
