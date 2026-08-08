{
  prometheus,
  stdenvNoCC,
}:
let
  catalog = import ./catalog.nix;
  sharePath = "share/prometheus-monitoring";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "prometheus-monitoring";
  version = "1";
  src = ./.;

  doCheck = true;
  nativeCheckInputs = [ prometheus.cli ];
  checkPhase = ''
    runHook preCheck

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
    cp -R prometheus "$out/${sharePath}/"
    runHook postInstall
  '';

  passthru = {
    prometheusRuleFiles = map (
      file: "${finalAttrs.finalPackage}/${sharePath}/prometheus/rules/${baseNameOf file}"
    ) catalog.prometheus.ruleFiles;
  };

  meta.description = "Prometheus alert rules";
})
