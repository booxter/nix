{
  config,
  lib,
  pkgs,
  ...
}:
let
  authority = config.host.pki.authority;
in
{
  system.activationScripts.postActivation.text = lib.mkIf (authority != null) (
    lib.mkAfter ''
      cert_path=${lib.escapeShellArg "${authority.rootCaCertificate}"}
      desired_sha256="$(${pkgs.openssl}/bin/openssl x509 -in "$cert_path" -noout -fingerprint -sha256 | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':')"

      if /usr/bin/security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | /usr/bin/grep -Fq "SHA-256 hash: $desired_sha256"; then
        echo "Internal PKI root CA already trusted in System keychain."
      else
        echo "Adding internal PKI root CA to System keychain."
        /usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_path"
      fi
    ''
  );
}
