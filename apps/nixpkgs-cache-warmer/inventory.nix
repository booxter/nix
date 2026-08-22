{
  excludePnamePatternsJson ? "[]",
  includePnamePatternsJson ? "[]",
  maintainer,
  nixpkgsSource,
  output ? "records",
  selectorsJson ? "null",
  system,
}:
let
  source = builtins.toPath nixpkgsSource;
  pkgs = import source {
    localSystem = { inherit system; };
  };
  ownedPackages = import (source + "/maintainers/scripts/build.nix") {
    inherit maintainer system;
  };
  selectors = builtins.fromJSON selectorsJson;
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
  packages =
    if selectors == null then
      ownedPackages
    else
      map (selector: pkgs.lib.getAttrFromPath selector pkgs) selectors;
  packagesByDrvPath = builtins.listToAttrs (
    map (pkg: {
      name = builtins.unsafeDiscardStringContext pkg.drvPath;
      value = pkg;
    }) (builtins.filter eligible packages)
  );
  selectedPackages = builtins.attrValues packagesByDrvPath;
  ownedByDrvPath = builtins.listToAttrs (
    map (pkg: {
      name = builtins.unsafeDiscardStringContext pkg.drvPath;
      value = true;
    }) ownedPackages
  );
  discoveredByDrvPath =
    let
      visit =
        path: set:
        pkgs.lib.flatten (
          pkgs.lib.mapAttrsToList (
            name: value:
            let
              result = builtins.tryEval (
                if pkgs.lib.isDerivation value then
                  let
                    drvPath = builtins.unsafeDiscardStringContext value.drvPath;
                  in
                  if builtins.hasAttr drvPath ownedByDrvPath then
                    [
                      {
                        inherit drvPath;
                        selector = path ++ [ name ];
                      }
                    ]
                  else
                    [ ]
                else if value.recurseForDerivations or false || value.recurseForRelease or false then
                  visit (path ++ [ name ]) value
                else
                  [ ]
              );
            in
            if result.success then result.value else [ ]
          ) set
        );
      preferShortest =
        discovered: candidate:
        discovered
        // {
          ${candidate.drvPath} =
            let
              previous = discovered.${candidate.drvPath} or null;
            in
            if previous == null || builtins.length candidate.selector < builtins.length previous then
              candidate.selector
            else
              previous;
        };
    in
    pkgs.lib.foldl' preferShortest { } (visit [ ] pkgs);
  discoveredSelectors = builtins.attrValues discoveredByDrvPath;
in
if output == "selectors" then
  discoveredSelectors
else if output == "packages" then
  map (pkg: pkg) selectedPackages
else
  map toRecord selectedPackages
