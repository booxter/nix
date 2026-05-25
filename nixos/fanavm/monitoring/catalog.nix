let
  alertmanagerConfigFile = ./alertmanager/alertmanager.yml;
  dnsRuleFile = ./prometheus/rules/dns.rules.yml;
  dnsTestFile = ./prometheus/tests/dns.rules.test.yml;
in
{
  alertmanager = {
    configFile = alertmanagerConfigFile;
    configRelative = "nixos/fanavm/monitoring/alertmanager/alertmanager.yml";
  };

  prometheus = {
    ruleFiles = [ dnsRuleFile ];
    ruleFilesRelative = [ "nixos/fanavm/monitoring/prometheus/rules/dns.rules.yml" ];
    testFiles = [ dnsTestFile ];
    testFilesRelative = [ "nixos/fanavm/monitoring/prometheus/tests/dns.rules.test.yml" ];
  };
}
