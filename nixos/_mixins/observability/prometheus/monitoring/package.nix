{
  formats,
  lib,
  prometheus,
  stdenvNoCC,
}:
let
  sharePath = "share/prometheus-monitoring";
  staticRuleNames = builtins.attrNames (
    lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".rules.yml" name) (
      builtins.readDir ./rules
    )
  );
  yaml = formats.yaml { };
  generatedRuleDefinitions = {
    "availability.rules.yml" = import ./rules/availability.nix { inherit lib; };
    "service-scrapes.rules.yml" = import ./rules/service-scrapes.nix { inherit lib; };
  };
  generatedRules = lib.mapAttrs (
    name: definition: yaml.generate name definition
  ) generatedRuleDefinitions;
  ruleNames = lib.unique (staticRuleNames ++ builtins.attrNames generatedRules);
  installGeneratedRules = lib.concatMapStringsSep "\n" (
    name: "cp ${generatedRules.${name}} rules/${lib.escapeShellArg name}"
  ) (builtins.attrNames generatedRules);
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "prometheus-monitoring";
  version = "1";
  src = ./.;

  doCheck = true;
  nativeCheckInputs = [ prometheus.cli ];
  postPatch = installGeneratedRules;
  checkPhase = ''
    runHook preCheck

    for rule_file in rules/*.rules.yml; do
      promtool check rules "$rule_file"
    done

    for test_file in tests/*.rules.test.yml; do
      test_dir="$(dirname "$test_file")"
      test_name="$(basename "$test_file")"
      (
        cd "$test_dir"
        promtool test rules "$test_name"
      )
    done

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/${sharePath}"
    cp -R rules "$out/${sharePath}/"
    runHook postInstall
  '';

  passthru = {
    prometheusRuleFiles = map (name: "${finalAttrs.finalPackage}/${sharePath}/rules/${name}") ruleNames;
  };

  meta.description = "Prometheus alert rules";
})
