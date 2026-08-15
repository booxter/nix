{
  pkgs,
  providerInventory ? { },
}:
let
  kanidmTools = pkgs.callPackage ./kanidm-tools { inherit providerInventory; };
in
{
  kanidm-person-mail-provision = kanidmTools;
  kanidm-mail-sender-bootstrap = kanidmTools;

  reset-oidc = kanidmTools;
}
