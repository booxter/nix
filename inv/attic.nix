{ lanDomain }:
rec {
  cacheName = "local";
  localDnsName = "nix-cache";
  serverHost = "cache";
  storageExport = "nixCache";
  endpoint = "https://${localDnsName}.${lanDomain}";
  substituterUrl = "${endpoint}/default";
}
