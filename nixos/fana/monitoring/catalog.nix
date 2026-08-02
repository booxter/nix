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
  llmRuleFile = ./prometheus/rules/llm.rules.yml;
  llmTestFile = ./prometheus/tests/llm.rules.test.yml;
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
  unifiRuleFile = ./prometheus/rules/unifi.rules.yml;
  unifiTestFile = ./prometheus/tests/unifi.rules.test.yml;
  wireguardRuleFile = ./prometheus/rules/wireguard.rules.yml;
  wireguardTestFile = ./prometheus/tests/wireguard.rules.test.yml;
in
{
  alertmanager = {
    configFile = alertmanagerConfigFile;
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
      llmRuleFile
      mediaPolicyRuleFile
      networkProbesRuleFile
      pkiRuleFile
      proxmoxRuleFile
      serviceProbesRuleFile
      serviceScrapesRuleFile
      storageRuleFile
      thermalRuleFile
      upsRuleFile
      unifiRuleFile
      wireguardRuleFile
    ];
    testFiles = [
      backupTestFile
      controlPlaneTestFile
      availabilityTestFile
      customJobsTestFile
      dnsTestFile
      fleetTestFile
      homeAssistantTestFile
      llmTestFile
      mediaPolicyTestFile
      networkProbesTestFile
      pkiTestFile
      proxmoxTestFile
      serviceProbesTestFile
      serviceScrapesTestFile
      storageTestFile
      thermalTestFile
      upsTestFile
      unifiTestFile
      wireguardTestFile
    ];
  };
}
