{
  hostSpecs,
  lib,
  readPublicKey,
  username,
}:
let
  purposes = {
    communityBuilderClient = "community-builder-client";
    gitSigning = "git-signing";
    gitSigningFallback = "git-signing-fallback";
    interactiveSsh = "interactive-ssh";
    personalBuilderClient = "personal-builder-client";
    remoteUnlock = "remote-unlock";
    sshFallback = "ssh-fallback";
    sshTicketCaSigning = "ssh-ticket-ca-signing";
    workBuilderClient = "work-builder-client";
  };
  operatorHostsForRealm =
    realm:
    map (spec: spec.name) (
      builtins.filter (spec: spec.realm == realm && (spec.isOperatorSeat or false)) hostSpecs
    );
  homeOperatorHosts = operatorHostsForRealm "home";
  workOperatorHosts = operatorHostsForRealm "work";
  mkIdentity =
    name:
    {
      kind,
      fileName,
      availableOn,
      purposes ? [ ],
      publicKey ? null,
      authorizedRealms ? [ ],
      authorizedHosts ? [ ],
      trustedCaRealms ? [ ],
    }:
    {
      inherit
        authorizedHosts
        authorizedRealms
        availableOn
        fileName
        kind
        name
        publicKey
        purposes
        trustedCaRealms
        ;
      owner = username;
    };
  mkPersonalFileIdentity =
    host: publicKeyFile: additionalPurposes:
    mkIdentity host {
      kind = "file";
      fileName = "id_ed25519";
      availableOn = [ host ];
      purposes = [
        purposes.gitSigningFallback
        purposes.personalBuilderClient
        purposes.sshFallback
      ]
      ++ additionalPurposes;
      publicKey = readPublicKey publicKeyFile;
      authorizedRealms = [ "home" ];
    };
  userIdentities = {
    frame = mkPersonalFileIdentity "frame" ../public-keys/users/frame.pub [ ];
    mair = mkPersonalFileIdentity "mair" ../public-keys/users/mair.pub [ purposes.remoteUnlock ];
    mmini = mkPersonalFileIdentity "mmini" ../public-keys/users/mmini.pub [ purposes.remoteUnlock ];

    work = mkIdentity "work" {
      kind = "file";
      fileName = "id_ed25519";
      availableOn = workOperatorHosts;
      purposes = [
        purposes.gitSigningFallback
        purposes.sshFallback
      ];
      publicKey = readPublicKey ../public-keys/users/jgwxhwdl4x.pub;
      authorizedRealms = [ "work" ];
    };

    workBuilder = mkIdentity "workBuilder" {
      kind = "file";
      fileName = "jgwxhwdl4x-nix-builder";
      availableOn = workOperatorHosts;
      purposes = [ purposes.workBuilderClient ];
      publicKey = readPublicKey ../public-keys/users/jgwxhwdl4x-nix-builder.pub;
      authorizedHosts = [ "nvws" ];
    };

    communityBuilder = mkIdentity "communityBuilder" {
      kind = "file";
      fileName = "nix-community-builders";
      availableOn = homeOperatorHosts;
      purposes = [ purposes.communityBuilderClient ];
    };

    yubikey = mkIdentity "yubikey" {
      kind = "resident";
      fileName = "id_ed25519_sk_rk";
      availableOn = [
        "frame"
        "mmini"
      ];
      purposes = [
        purposes.gitSigning
        purposes.interactiveSsh
        purposes.sshTicketCaSigning
      ];
      publicKey = readPublicKey ../public-keys/yubikey.pub;
      authorizedRealms = [ "home" ];
      trustedCaRealms = [ "home" ];
    };

    mairSecretive = mkIdentity "mairSecretive" {
      kind = "agent";
      fileName = "secretive.pub";
      availableOn = [ "mair" ];
      purposes = [
        purposes.gitSigning
        purposes.interactiveSsh
      ];
      publicKey = readPublicKey ../public-keys/mair-secretive.pub;
      authorizedRealms = [ "home" ];
    };

    fleetUserCa = mkIdentity "fleetUserCa" {
      kind = "agent";
      fileName = "fleet-user-ca.pub";
      availableOn = [ "mair" ];
      purposes = [ purposes.sshTicketCaSigning ];
      publicKey = readPublicKey ../public-keys/ssh-ca/fleet-user-ca.pub;
      trustedCaRealms = [ "home" ];
    };
  };
  identityValues = builtins.attrValues userIdentities;
  identitiesForPurpose =
    purpose: builtins.filter (identity: builtins.elem purpose identity.purposes) identityValues;
  identityFor =
    host: purpose:
    let
      matches = builtins.filter (
        identity: builtins.elem host identity.availableOn && builtins.elem purpose identity.purposes
      ) identityValues;
      matchNames = lib.concatMapStringsSep ", " (identity: identity.name) matches;
    in
    if builtins.length matches == 1 then
      builtins.head matches
    else
      throw "host ${host} must have exactly one SSH identity for ${purpose}; found: ${matchNames}";
  publicKeysMatching =
    predicate:
    map (
      identity:
      if identity.publicKey == null then
        throw "SSH identity ${identity.name} grants authorization without a public key"
      else
        identity.publicKey
    ) (builtins.filter predicate identityValues);
in
{
  inherit
    identitiesForPurpose
    identityFor
    purposes
    userIdentities
    ;

  authorizedKeysForRealm =
    realm: publicKeysMatching (identity: builtins.elem realm identity.authorizedRealms);
  authorizedKeysForHost =
    host: publicKeysMatching (identity: builtins.elem host identity.authorizedHosts);
  trustedCaPublicKeysForRealm =
    realm: publicKeysMatching (identity: builtins.elem realm identity.trustedCaRealms);
}
