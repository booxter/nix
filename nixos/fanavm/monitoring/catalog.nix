let
  alertmanagerConfigFile = ./alertmanager/alertmanager.yml;
  backupRuleFile = ./prometheus/rules/backup.rules.yml;
  backupTestFile = ./prometheus/tests/backup.rules.test.yml;
  controlPlaneRuleFile = ./prometheus/rules/control-plane.rules.yml;
  controlPlaneTestFile = ./prometheus/tests/control-plane.rules.test.yml;
  availabilityRuleFile = ./prometheus/rules/availability.rules.yml;
  availabilityTestFile = ./prometheus/tests/availability.rules.test.yml;
  customJobsRuleFile = ./prometheus/rules/custom-jobs.rules.yml;
  customJobsTestFile = ./prometheus/tests/custom-jobs.rules.test.yml;
  dnsRuleFile = ./prometheus/rules/dns.rules.yml;
  dnsTestFile = ./prometheus/tests/dns.rules.test.yml;
  fleetRuleFile = ./prometheus/rules/fleet.rules.yml;
  fleetTestFile = ./prometheus/tests/fleet.rules.test.yml;
  mediaPolicyRuleFile = ./prometheus/rules/media-policy.rules.yml;
  mediaPolicyTestFile = ./prometheus/tests/media-policy.rules.test.yml;
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
      backupRuleFile
      controlPlaneRuleFile
      availabilityRuleFile
      customJobsRuleFile
      dnsRuleFile
      fleetRuleFile
      mediaPolicyRuleFile
      networkProbesRuleFile
      pkiRuleFile
      serviceProbesRuleFile
      serviceScrapesRuleFile
      storageRuleFile
      thermalRuleFile
      upsRuleFile
    ];
    ruleFilesRelative = [
      "nixos/fanavm/monitoring/prometheus/rules/backup.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/control-plane.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/availability.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/custom-jobs.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/dns.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/fleet.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/media-policy.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/network-probes.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/pki.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/service-probes.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/service-scrapes.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/storage.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/thermal.rules.yml"
      "nixos/fanavm/monitoring/prometheus/rules/ups.rules.yml"
    ];
    testFiles = [
      backupTestFile
      controlPlaneTestFile
      availabilityTestFile
      customJobsTestFile
      dnsTestFile
      fleetTestFile
      mediaPolicyTestFile
      networkProbesTestFile
      pkiTestFile
      serviceProbesTestFile
      serviceScrapesTestFile
      storageTestFile
      thermalTestFile
      upsTestFile
    ];
    testFilesRelative = [
      "nixos/fanavm/monitoring/prometheus/tests/backup.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/control-plane.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/availability.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/custom-jobs.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/dns.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/fleet.rules.test.yml"
      "nixos/fanavm/monitoring/prometheus/tests/media-policy.rules.test.yml"
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
