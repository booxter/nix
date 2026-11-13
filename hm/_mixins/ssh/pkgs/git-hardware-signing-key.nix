{
  lib,
  writeShellApplication,
  openssh,
  gawk,
  approvedKeysFile,
  localIdentityFiles ? [ ],
}:
writeShellApplication {
  name = "git-hardware-signing-key";
  runtimeInputs = [
    openssh
    gawk
  ];
  text =
    lib.optionalString (localIdentityFiles != [ ]) ''
      # A remote session must use its forwarded agent, never the destination's key.
      if [[ -z "''${SSH_CONNECTION:-}" ]]; then
        ssh-add -q ${lib.escapeShellArgs localIdentityFiles}
      fi
    ''
    + ''
      # Compare key material, since agents may use different comments for a key.
      # Read the entire list to avoid SIGPIPE when the agent has several keys.
      ssh-add -L | awk '
        NR == FNR {
          approved[$1 " " $2] = 1
          next
        }
        !found && approved[$1 " " $2] {
          print "key::" $1 " " $2
          found = 1
        }
        END {
          if (!found) {
            print "No approved hardware signing key is available in the SSH agent." > "/dev/stderr"
            exit 1
          }
        }
      ' ${approvedKeysFile} -
    '';
}
