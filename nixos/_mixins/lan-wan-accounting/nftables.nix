{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg tableName;
  # TODO: Migrate the fleet firewall backend to nftables, then let
  # networking.nftables.tables own this table instead of this service.
  rules = import ./rules.nix {
    inherit config lib tableName;
  };
  rulesFile = pkgs.writeTextFile {
    name = "lan-wan-accounting.nft";
    text = rules;
    checkPhase = ''
      LD_PRELOAD="${pkgs.buildPackages.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
        ${pkgs.buildPackages.nftables}/bin/nft --check --file "$out"
    '';
  };
  nft = lib.getExe pkgs.nftables;
  loadCommand = utils.escapeSystemdExecArgs [
    nft
    "--file"
    rulesFile
  ];
  removeCommand = utils.escapeSystemdExecArgs [
    nft
    "delete"
    "table"
    "inet"
    tableName
  ];
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.observability-lan-wan-accounting = {
      description = "Own the nftables LAN/WAN accounting table";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-pre.target"
        "sysinit.target"
      ];
      after = [ "sysinit.target" ];
      before = [
        "network-pre.target"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      reloadIfChanged = true;
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = loadCommand;
        ExecReload = loadCommand;
        ExecStop = "-${removeCommand}";
      };
    };
  };
}
