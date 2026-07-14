# `home`

`home` is the fleet Home Assistant service. It is available at
`https://home.home.arpa` and uses the native NixOS Home Assistant module.

## Configuration model

- `configuration.yaml`, the Lovelace dashboard, components, automations,
  scenes, and scripts are generated read-only from Nix.
- Home Assistant still owns mutable runtime state, including the entity and
  device registries, OIDC credential links, history, and discovered device
  state. That state is backed up rather than committed.
- The packaged `auth_oidc` component connects Home Assistant to Kanidm. The
  `home-admins` and `home-users` claims map to Home Assistant roles.
- A first-boot oneshot uses the SOPS-managed bootstrap password to create the
  inventory-selected Home Assistant owner and complete onboarding through the
  supported HTTP API. The owner's first OIDC login links to that account.

## Observability

Home Assistant listens on loopback. Nginx exposes the browser UI with the
internal service certificate, while `/api/prometheus` is exposed separately
through an mTLS-only endpoint for fana. Host logs are shipped to Loki by the
standard observability client.

## Backup

Before restic runs, `home-assistant-native-backup.service` asks Home Assistant's
native backup manager to create a local archive containing the configuration
and recorder database. Home Assistant retains the seven newest local archives;
those archives and the remaining runtime state are pushed to the dedicated
`home` repository on beast and then copied to B2. The live recorder database is
excluded from restic because its consistent copy is already inside the native
archive.

Before the first deployment:

1. Bootstrap `secrets/home.yaml` with the VM's age recipient.
2. Replace the bootstrap password and host password placeholders.
3. Replace `public-keys/hosts/home.pub` with the installed VM SSH host key.
4. Generate the restic SSH keypair, commit the public key at
   `public-keys/restic/home.pub`, and store the private key in SOPS.
5. Issue the `home` internal HTTPS certificate and the Home Assistant and node
   observability certificates with the fleet PKI apps.
6. Replace the new beast cloud-repository password placeholders.
