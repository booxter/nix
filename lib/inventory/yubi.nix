{
  frame,
  mmini,
  username,
}:
{
  # Public YubiKey allocation facts. Keep PINs, PUKs, management keys, and
  # private key material out of inventory.
  devices.personal = {
    owner = username;
    hosts = [
      frame
      mmini
    ];

    applets = {
      fido2 = {
        residentSsh = {
          keyName = "id_ed25519_sk_rk";
          hosts = [
            frame
            mmini
          ];
          purposes = [
            "ssh-client-auth"
            "git-ssh-signing"
            "ssh-ticket-ca-signing"
          ];
        };

        pamU2f.${frame} = {
          host = frame;
          appId = "pam://${frame}";
          origin = "pam://${frame}";
        };
      };

      piv = {
        managementKey = {
          algorithm = "TDES";
          storage = "protected-by-pin";
        };

        occupiedSlots = {
          "9A" = {
            host = mmini;
            purpose = "macOS SmartCardServices login";
            subject = "CN=ihrachyshka@mmini PIV auth";
            certificateSha1 = "EE:44:3A:CB:F7:9B:70:13:C2:9A:D8:53:1C:47:25:F3:FF:4C:57:85";
            macosIdentityHash = "1CD7472BD8C5B0129801906597B581CC8FE05968";
            macosToken = "com.apple.pivtoken:9F19388BE1FB4DEF83A8F2AC72223BF6";
          };

          "9D" = {
            host = mmini;
            purpose = "PIV key management certificate";
            subject = "CN=ihrachyshka@mmini PIV key management";
            certificateSha1 = "8F:60:00:48:80:3B:94:E8:DB:6A:E9:28:41:8C:EF:8E:3A:3B:EF:C7";
          };
        };

        retiredSlots = {
          "1" = {
            hosts = [
              frame
              mmini
            ];
            purpose = "age-plugin-yubikey sops identity";
            name = "nix sops age";
            recipient = "age1yubikey1qgnnyzk9ftl6uetyk6r8kd8eqxe7emcsgedaq7jycjk6sxt483p55chyk9r";
            identityFileName = "yubi-nix.txt";
            pinPolicy = "once";
            touchPolicy = "cached";
          };
        };
      };
    };
  };
}
