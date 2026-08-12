{
  config,
  lib,
  tableName,
}:
let
  cfg = config.host.observability.lanWan;
  interfacePathMode = cfg.mode == "interface-path";
  override = cfg.wanEgressOverride;
  overrideEnabled = override != null;
  inputChain = if interfacePathMode then "prerouting" else "input";
  outputChain = if interfacePathMode then "postrouting" else "output";
  inputInterfaceFilter = lib.optionalString (cfg.interface != null) ''
    iifname != "${cfg.interface}" return
  '';
  outputInterfaceFilter = lib.optionalString (cfg.interface != null) ''
    oifname != "${cfg.interface}" return
  '';
  elements =
    values: lib.optionalString (values != [ ]) "elements = { ${lib.concatStringsSep ", " values} }";
  overrideRules = lib.optionalString overrideEnabled (
    lib.concatStringsSep "\n    " [
      ''udp dport ${toString override.udpDestinationPort} counter name "${override.name}_out" counter name "wan_out" return''
      ''counter name "wan_other_out"''
    ]
  );
in
''
  # Declare before deleting so replacement also succeeds on first activation.
  table inet ${tableName}
  delete table inet ${tableName}

  table inet ${tableName} {
    set lan_nets {
      type ipv4_addr
      flags interval
      ${elements cfg.lanSubnets}
    }

    set lan_nets6 {
      type ipv6_addr
      flags interval
      ${elements cfg.lanSubnets6}
    }

    counter lan_in {}
    counter wan_in {}
    counter lan_out {}
    counter wan_out {}
    ${lib.optionalString overrideEnabled "counter ${override.name}_out {}"}
    ${lib.optionalString overrideEnabled "counter wan_other_out {}"}

    chain ${inputChain} {
      type filter hook ${inputChain} priority mangle; policy accept;
      iifname "lo" return
      ${inputInterfaceFilter}
      ip saddr @lan_nets counter name "lan_in" return
      ip6 saddr @lan_nets6 counter name "lan_in" return
      counter name "wan_in"
    }

    chain ${outputChain} {
      type filter hook ${outputChain} priority mangle; policy accept;
      oifname "lo" return
      ${outputInterfaceFilter}
      ip daddr @lan_nets counter name "lan_out" return
      ip6 daddr @lan_nets6 counter name "lan_out" return
      ${overrideRules}
      counter name "wan_out"
    }
  }
''
