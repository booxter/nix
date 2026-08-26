{
  config,
  lib,
  ...
}:
let
  authority = config.host.pki.authority;
in
{
  system.activationScripts.postActivation.text = lib.mkIf (authority != null) (
    lib.mkAfter ''
      cert_path=${lib.escapeShellArg "${authority.rootCaCertificate}"}

      if /usr/bin/security verify-cert -q -L -c "$cert_path" -p basic; then
        echo "Internal PKI root CA already trusted in System keychain."
      else
        echo "Adding internal PKI root CA to System keychain."
        /usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_path"
        /usr/bin/security verify-cert -q -L -c "$cert_path" -p basic
      fi
    ''
  );
}
