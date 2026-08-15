{ config }:
let
  authority = config.host.pki.authority;
in
if authority == null then
  null
else
  authority
  // {
    port = 8443;
    rootsPath = "/roots.pem";
    url = "https://${authority.hostName}.${config.host.network.lanDomain}:8443";
    provisioner = "bootstrap@${config.host.network.lanDomain}";
    leafLifetimeDays = 180;
    certificateLifetime = "4320h0m0s";
    displayName =
      if config.host.realm == "home" then "Home Internal PKI" else "${config.host.realm} Internal PKI";
  }
