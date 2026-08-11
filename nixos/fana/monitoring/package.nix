{
  formats,
  gettext,
  facts,
  lib,
  prometheus,
  prometheus-alertmanager,
  stdenvNoCC,
}:
let
  catalog = import ./catalog.nix;
  sharePath = "share/fana-monitoring";
  yaml = formats.yaml { };
  generatedRuleDefinitions = {
    "availability.rules.yml" = import ./prometheus/rules/availability.nix {
      inherit lib;
    };
    "capacity.rules.yml" = import ./prometheus/rules/capacity.nix { inherit facts lib; };
    "launchd.rules.yml" = import ./prometheus/rules/launchd.nix { inherit lib; };
    "service-scrapes.rules.yml" = import ./prometheus/rules/service-scrapes.nix { inherit lib; };
    "systemd.rules.yml" = import ./prometheus/rules/systemd.nix { inherit lib; };
  };
  generatedRules = lib.mapAttrs (
    name: definition: yaml.generate name definition
  ) generatedRuleDefinitions;
  generatedRuleFiles =
    finalPackage:
    map (name: "${finalPackage}/${sharePath}/prometheus/rules/${name}") (
      builtins.attrNames generatedRules
    );
  installGeneratedRules = lib.concatMapStringsSep "\n" (
    name: "cp ${generatedRules.${name}} prometheus/rules/${lib.escapeShellArg name}"
  ) (builtins.attrNames generatedRules);
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "fana-monitoring";
  version = "1";
  src = ./.;

  doCheck = true;
  nativeCheckInputs = [
    gettext
    prometheus.cli
    prometheus-alertmanager
  ];
  postPatch = installGeneratedRules;
  checkPhase = ''
    runHook preCheck

    export TELEGRAM_CHAT_ID='-1000000000000'
    envsubst < alertmanager/alertmanager.yml > alertmanager.rendered.yml
    amtool check-config alertmanager.rendered.yml

    for rule_file in prometheus/rules/*.rules.yml; do
      promtool check rules "$rule_file"
    done

    for test_file in prometheus/tests/*.rules.test.yml; do
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
    cp -R alertmanager prometheus "$out/${sharePath}/"
    runHook postInstall
  '';

  passthru = {
    prometheusRuleFiles =
      generatedRuleFiles finalAttrs.finalPackage
      ++ map (
        file: "${finalAttrs.finalPackage}/${sharePath}/prometheus/rules/${baseNameOf file}"
      ) catalog.prometheus.ruleFiles;
  };

  meta.description = "Fana Alertmanager configuration and Prometheus alert rules";
})
