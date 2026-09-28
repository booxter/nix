let
  requestPath = builtins.getEnv "PACKAGE_RISK_REQUEST_PATH";
  request = builtins.fromJSON (builtins.readFile requestPath);
  flake = builtins.getFlake request.flakeRef;
  configurations =
    if request.kind == "nixos" then flake.nixosConfigurations else flake.darwinConfigurations;
  pkgs = configurations.${request.config}.pkgs;

  isAttrs = builtins.isAttrs;
  isDerivation = value: isAttrs value && (value.type or null) == "derivation";

  safeAttr =
    attrs: name:
    let
      result = builtins.tryEval (
        if isAttrs attrs && builtins.hasAttr name attrs then builtins.getAttr name attrs else null
      );
    in
    if result.success then result.value else null;

  attrByPath =
    path: attrs:
    if path == [ ] then
      attrs
    else
      let
        value = safeAttr attrs (builtins.head path);
      in
      if value == null then null else attrByPath (builtins.tail path) value;

  candidateAt =
    packageSet: path:
    let
      result = builtins.tryEval (attrByPath path packageSet);
    in
    if result.success && isDerivation result.value then result.value else null;

  outputPaths =
    drv: builtins.map (output: (builtins.getAttr output drv).outPath) (drv.outputs or [ "out" ]);

  firstMatch =
    component: candidates:
    if candidates == [ ] then
      null
    else
      let
        path = builtins.head candidates;
        candidate = candidateAt pkgs path;
        drvPath = builtins.tryEval candidate.drvPath;
        outputs = builtins.tryEval (outputPaths candidate);
        matches =
          candidate != null
          && drvPath.success
          && (
            (component.drvPath != "" && drvPath.value == component.drvPath)
            || (outputs.success && builtins.elem component.outputPath outputs.value)
          );
      in
      if matches then { inherit candidate path; } else firstMatch component (builtins.tail candidates);

  labelMaintainer = maintainer: maintainer.github or maintainer.name or maintainer.email or "unknown";
  labelTeam = team: team.github or team.name or "unknown";
  packageMeta =
    drv:
    let
      meta = drv.meta or { };
    in
    {
      maintainers = builtins.map labelMaintainer (builtins.filter isAttrs (meta.maintainers or [ ]));
      teams = builtins.map labelTeam (builtins.filter isAttrs (meta.teams or [ ]));
      knownVulnerabilities = meta.knownVulnerabilities or [ ];
      position = meta.position or "";
    };

  inputPackageSet = name: attrByPath [ "inputs" name "legacyPackages" request.system ] flake;
  inputComparisons = builtins.map (name: {
    label = name;
    packageSet = inputPackageSet name;
  }) request.comparisonInputs;

  externalComparison =
    comparison:
    let
      source = builtins.getFlake comparison.flakeRef;
    in
    {
      inherit (comparison) label;
      packageSet = attrByPath [ "legacyPackages" request.system ] source;
    };
  comparisons = inputComparisons ++ builtins.map externalComparison request.externalComparisons;

  versionIn =
    path: comparison:
    let
      drv = candidateAt comparison.packageSet path;
      value =
        if drv == null then
          null
        else
          {
            inherit (comparison) label;
            version = drv.version or "";
            knownVulnerabilities = (drv.meta or { }).knownVulnerabilities or [ ];
          };
      forced = builtins.tryEval (builtins.deepSeq value value);
    in
    if forced.success then forced.value else null;

  row =
    component:
    let
      match = firstMatch component component.candidatePaths;
      value =
        if match == null then
          null
        else
          {
            drvPath = match.candidate.drvPath;
            name = match.candidate.name;
            pname = match.candidate.pname or match.candidate.name;
            version = match.candidate.version or "";
            attrPath = match.path;
            meta = packageMeta match.candidate;
            comparisons = builtins.filter (comparison: comparison != null) (
              builtins.map (versionIn match.path) comparisons
            );
          };
      forced = builtins.tryEval (builtins.deepSeq value value);
    in
    if forced.success then forced.value else null;
in
{
  components = builtins.filter (component: component != null) (builtins.map row request.components);
}
