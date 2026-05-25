let
  alertmanagerConfigFile = ./alertmanager/alertmanager.yml;
  availabilityRuleFile = ./prometheus/rules/availability.rules.yml;
  availabilityTestFile = ./prometheus/tests/availability.rules.test.yml;
  dnsRuleFile = ./prometheus/rules/dns.rules.yml;
  dnsTestFile = ./prometheus/tests/dns.rules.test.yml;
  networkProbesRuleFile = ./prometheus/rules/network-probes.rules.yml;
  networkProbesTestFile = ./prometheus/tests/network-probes.rules.test.yml;
  pkiRuleFile = ./prometheus/rules/pki.rules.yml;
  pkiTestFile = ./prometheus/tests/pki.rules.test.yml;
  serviceProbesRuleFile = ./prometheus/rules/service-probes.rules.yml;
  serviceProbesTestFile = ./prometheus/tests/service-probes.rules.test.yml;
  serviceScrapesRuleFile = ./prometheus/rules/service-scrapes.rules.yml;
  serviceScrapesTestFile = ./prometheus/tests/service-scrapes.rules.test.yml;
  storageRuleFile = ./prometheus/rules/storage.rules.yml;
  storageTestFile = ./prometheus/tests/storage.rules.test.yml;
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
      availabilityRuleFile
      dnsRuleFile
      networkProbesRuleFile
      pkiRuleFile
      serviceProbesRuleFile
      serviceScrapesRuleFile
      storageRuleFile
      thermalRuleFile
      upsRuleFile
    ];
    ruleFilesRelative = [
      "nixos/fanavm/monitoring/prometheus/rules/availability.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/dns.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/network-probes.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/pki.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/service-probes.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/service-scrapes.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/storage.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/thermal.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/ups.rules.yml"
    ];
    testFiles = [
      availabilityTestFile
      dnsTestFile
      networkProbesTestFile
      pkiTestFile
      serviceProbesTestFile
      serviceScrapesTestFile
      storageTestFile
      thermalTestFile
      upsTestFile
    ];
    testFilesRelative = [
      "nixos/fanavm/monitoring/prometheus/tests/availability.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/dns.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/network-probes.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/pki.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/service-probes.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/service-scrapes.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/storage.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/thermal.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/ups.rules.test.yml"
    ];
  };
}
