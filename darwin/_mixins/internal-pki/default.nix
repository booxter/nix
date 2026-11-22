{
  config,
  lib,
  ...
}:
let
  authority = config.host.pki.authority;
in
{
  options.host.pki.requireSystemKeychainTrust = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Fail activation when the internal CA cannot be trusted in the System keychain.";
  };

  config.system.activationScripts.postActivation.text = lib.mkIf (authority != null) (
    lib.mkAfter ''
      cert_path=${lib.escapeShellArg "${authority.rootCaCertificate}"}

      if /usr/bin/security verify-cert -q -L -c "$cert_path" -p basic; then
        echo "Internal PKI root CA already trusted in System keychain."
      else
        echo "Adding internal PKI root CA to System keychain."
        if /usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_path" &&
           /usr/bin/security verify-cert -q -L -c "$cert_path" -p basic; then
          echo "Internal PKI root CA trusted in System keychain."
        else
          echo "WARNING: Internal PKI root CA trust in System keychain could not be established; applications using it may reject internal HTTPS certificates." >&2
          ${lib.optionalString config.host.pki.requireSystemKeychainTrust "exit 1"}
        fi
      fi
    ''
  );
}
