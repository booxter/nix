{ lib }:
facts:
let
  dnsDomains = map (record: record.domain) facts.lan.dnsRecords;
in
[
  {
    assertion = builtins.length dnsDomains == builtins.length (lib.unique dnsDomains);
    message = "site DNS records must use unique domains";
  }
]
