{
  config,
  extendModules,
  lib,
  pkgs,
  sshKeys,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  ciVmBuild =
    (extendModules {
      modules = [ { virtualisation.vmVariant = import ../../ci/darwin-vm.nix; } ];
    }).config.virtualisation.vmVariant.system.build;
in
{
  imports = [ ./opencode.nix ];

  system.stateVersion = 6;

  system.build.ciVm = ciVmBuild.vm;
  system.build.ciVmIpsw = ciVmBuild.ipsw;

  # TODO: Revisit on macOS 27+. Tahoe repeatedly cached identical app icons on mair.
  # Other reports of the shared icon store filling the disk:
  # https://github.com/manaflow-ai/cmux/issues/22627
  # https://github.com/block/buzz/issues/8266
  launchd.daemons.icon-cache-prune = {
    command = "/usr/bin/find /Library/Caches/com.apple.iconservices.store -maxdepth 1 -type f -name '*.isdata' -Btime +7d -delete";
    serviceConfig = {
      RunAtLoad = true;
      StartInterval = 3600;
      StandardOutPath = "/var/log/nix-darwin/icon-cache-prune.log";
      StandardErrorPath = "/var/log/nix-darwin/icon-cache-prune.log";
    };
  };

  home-manager.users.${username} = {
    host.hm.pass.yubikey = "laptop";

    host.hm.dev.agents.mcp.stdioServers.firefox-devtools = {
      instructions = ''
        Only use the Firefox DevTools MCP when the user explicitly requests browser
        interaction or browser-based debugging.
      '';
      command = lib.getExe pkgs.firefox-devtools-mcp;
      args = [
        "--firefox-path"
        "${hmConfig.home.homeDirectory}/Applications/Home Manager Apps/Firefox.app/Contents/MacOS/firefox"
        "--profile-path"
        "${hmConfig.xdg.dataHome}/firefox-devtools-mcp"
        "--accept-insecure-certs"
        "--viewport"
        "1440x1000"
      ];
    };
  };

  host = {
    hardware.isLaptop = true;
    nix.builderClient = { };
    network.interfaces.en0.kind = "wireless";
    security = {
      secrets.operator.ageIdentity = {
        backend = "secure-enclave";
        path = "/Users/${username}/.config/sops/age/mair-se.txt";
      };
    };
    remote-control = {
      client = {
        vnc = { };
        wayland = { };
        x11 = { };
      };
      server.vnc = { };
    };
    ssh = {
      credentials = {
        backend = "secretive";
        secretive.publicKey = sshKeys.keys.mairSecretive;
      };
      operator.authorizedKeys = sshKeys.operators.mair;
      tickets.issuer = {
        publicKey = sshKeys.ticketIssuers.mair;
        keyName = "fleet-user-ca.pub";
        useAgent = true;
      };
    };
  };

}
