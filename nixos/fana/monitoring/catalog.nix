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
  homeAssistantRuleFile = ./prometheus/rules/home-assistant.rules.yml;
  homeAssistantTestFile = ./prometheus/tests/home-assistant.rules.test.yml;
  mediaPolicyRuleFile = ./prometheus/rules/media-policy.rules.yml;
  mediaPolicyTestFile = ./prometheus/tests/media-policy.rules.test.yml;
  networkProbesRuleFile = ./prometheus/rules/network-probes.rules.yml;
  networkProbesTestFile = ./prometheus/tests/network-probes.rules.test.yml;
  pkiRuleFile = ./prometheus/rules/pki.rules.yml;
  pkiTestFile = ./prometheus/tests/pki.rules.test.yml;
  proxmoxRuleFile = ./prometheus/rules/proxmox.rules.yml;
  proxmoxTestFile = ./prometheus/tests/proxmox.rules.test.yml;
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
  wireguardRuleFile = ./prometheus/rules/wireguard.rules.yml;
  wireguardTestFile = ./prometheus/tests/wireguard.rules.test.yml;
in
{
  alertmanager = {
    configFile = alertmanagerConfigFile;
    configRelative = "nixos/fana/monitoring/alertmanager/alertmanager.yml";
  };

  prometheus = {
    ruleFiles = [
      backupRuleFile
      controlPlaneRuleFile
      availabilityRuleFile
      customJobsRuleFile
      dnsRuleFile
      fleetRuleFile
      homeAssistantRuleFile
      mediaPolicyRuleFile
      networkProbesRuleFile
      pkiRuleFile
      proxmoxRuleFile
      serviceProbesRuleFile
      serviceScrapesRuleFile
      storageRuleFile
      thermalRuleFile
      upsRuleFile
      wireguardRuleFile
    ];
    ruleFilesRelative = [
      "nixos/fana/monitoring/prometheus/rules/backup.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/control-plane.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/availability.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/custom-jobs.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/dns.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/fleet.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/home-assistant.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/media-policy.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/network-probes.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/pki.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/proxmox.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/service-probes.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/service-scrapes.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/storage.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/thermal.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/ups.rules.yml"
      "nixos/fana/monitoring/prometheus/rules/wireguard.rules.yml"
    ];
    testFiles = [
      backupTestFile
      controlPlaneTestFile
      availabilityTestFile
      customJobsTestFile
      dnsTestFile
      fleetTestFile
      homeAssistantTestFile
      mediaPolicyTestFile
      networkProbesTestFile
      pkiTestFile
      proxmoxTestFile
      serviceProbesTestFile
      serviceScrapesTestFile
      storageTestFile
      thermalTestFile
      upsTestFile
      wireguardTestFile
    ];
    testFilesRelative = [
      "nixos/fana/monitoring/prometheus/tests/backup.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/control-plane.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/availability.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/custom-jobs.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/dns.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/fleet.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/home-assistant.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/media-policy.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/network-probes.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/pki.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/proxmox.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/service-probes.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/service-scrapes.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/storage.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/thermal.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/ups.rules.test.yml"
      "nixos/fana/monitoring/prometheus/tests/wireguard.rules.test.yml"
    ];
  };
}
