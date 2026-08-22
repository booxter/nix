{
  fleetHosts,
  lib,
}:
let
  readPublicKey = import ../common/_lib/read-public-key.nix { inherit lib; };
  workHosts = [
    "JGWXHWDL4X"
    "nv"
    "nvws"
  ];
  operatorKeyFiles = {
    JGWXHWDL4X = [
      ../common/_mixins/ssh/public-keys/jgwxhwdl4x.pub
      ../common/_mixins/ssh/public-keys/jgwxhwdl4x-nix-builder.pub
    ];
    frame = [
      ../common/_mixins/ssh/public-keys/frame.pub
      ../common/_mixins/ssh/public-keys/yubikey.pub
    ];
    mair = [
      ../common/_mixins/ssh/public-keys/mair.pub
      ../common/_mixins/ssh/public-keys/mair-secretive.pub
    ];
    mmini = [
      ../common/_mixins/ssh/public-keys/mmini.pub
      ../common/_mixins/ssh/public-keys/yubikey.pub
    ];
  };
  prometheusEndpointInventory.beast.jellyfin = {
    port = 9594;
    path = "/metrics";
  };
  ticketIssuerKeyFiles = {
    frame = ../common/_mixins/ssh/public-keys/yubikey.pub;
    mair = ../common/_mixins/ssh/public-keys/fleet-user-ca.pub;
    mmini = ../common/_mixins/ssh/public-keys/yubikey.pub;
  };
  defaultTicketPolicy = {
    allowX11Forwarding = false;
    defaultTtl = "30m";
    maxTtl = "2h";
  };
  ticketPolicyOverrides.frame.allowX11Forwarding = true;
  vncInventory = {
    frame = {
      connection = "ssh-tunnel";
      displays = [
        {
          name = "left";
          port = 5933;
          primary = true;
        }
        {
          name = "right";
          port = 5934;
          primary = false;
        }
      ];
    };
    mair = {
      connection = "direct";
      displays = [ ];
    };
    mmini = {
      connection = "direct";
      displays = [ ];
    };
  };
  knownHostNamesFor =
    platform: name:
    let
      lowercaseName = lib.toLower name;
    in
    lib.unique (
      [ name ]
      ++ lib.optional (lowercaseName != name) lowercaseName
      ++ lib.optional (platform == "nixos") "${name}.home.arpa"
      ++ [ "${name}.local" ]
      ++ lib.optional (lowercaseName != name) "${lowercaseName}.local"
    );
  hostFor = platform: system: name: path: {
    inherit platform system;
    observability.prometheusEndpoints = prometheusEndpointInventory.${name} or { };
    realm = if builtins.elem name workHosts then "work" else "home";
    site = "home";
    remoteControl.vnc = vncInventory.${name} or null;
    ssh = {
      knownHostNames = knownHostNamesFor platform name;
      operatorAuthorizedKeys = map readPublicKey (operatorKeyFiles.${name} or [ ]);
      publicHostKey = readPublicKey (path + "/ssh_host_ed25519_key.pub");
      ticketIssuerPublicKey =
        if builtins.hasAttr name ticketIssuerKeyFiles then
          readPublicKey ticketIssuerKeyFiles.${name}
        else
          null;
      ticketPolicy = defaultTicketPolicy // (ticketPolicyOverrides.${name} or { });
    };
  };
in
lib.mapAttrs (hostFor "nixos" "x86_64-linux") fleetHosts.nixos
// lib.mapAttrs (hostFor "darwin" "aarch64-darwin") fleetHosts.darwin
