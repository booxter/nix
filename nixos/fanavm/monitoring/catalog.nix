let
  alertmanagerConfigFile = ./alertmanager/alertmanager.yml;
  dnsRuleFile = ./prometheus/rules/dns.rules.yml;
  dnsTestFile = ./prometheus/tests/dns.rules.test.yml;
  pkiRuleFile = ./prometheus/rules/pki.rules.yml;
  pkiTestFile = ./prometheus/tests/pki.rules.test.yml;
  thermalRuleFile = ./prometheus/rules/thermal.rules.yml;
  thermalTestFile = ./prometheus/tests/thermal.rules.test.yml;
  upsRuleFile = ./prometheus/rules/ups.rules.yml;
  upsTestFile = ./prometheus/tests/ups.rules.test.yml;
in
{
  alertmanager = {
    configFile = alertmanagerConfigFile;
    configRelative = "nixos/fanavm/monitoring/alertmanager/alertmanager.yml";
  };

  prometheus = {
    ruleFiles = [
      dnsRuleFile
      pkiRuleFile
      thermalRuleFile
      upsRuleFile
    ];
    ruleFilesRelative = [
      "nixos/fanavm/monitoring/prometheus/rules/dns.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/pki.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/thermal.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/ups.rules.yml"
    ];
    testFiles = [
      dnsTestFile
      pkiTestFile
      thermalTestFile
      upsTestFile
    ];
    testFilesRelative = [
      "nixos/fanavm/monitoring/prometheus/tests/dns.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/pki.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/thermal.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/ups.rules.test.yml"
    ];
  };
}
