# SSO/OIDC Rollout Plan

Working document for moving human-facing services in this fleet to one
identity source and a consistent SSO policy.

## Goal

- Run a self-hosted OIDC identity provider on `pki`.
- Define users and groups once.
- Use native OIDC in applications that support it.
- Use `oauth2-proxy` plus nginx `auth_request` for admin tools that do not
  support OIDC.
- Keep app-local API keys, automation tokens, and break-glass admin accounts
  in sops.

## Non-Goals For The First Pass

- Do not change Transmission. It is currently unauthenticated and will be
  handled separately.
- Do not migrate Jellyfin yet. It is important, but requires a dedicated pass
  because of media clients, library permissions, and the current Jellarr-managed
  user policy.
- Do not remove local passwords or local admin accounts until each service has
  been validated through SSO and rollback is understood.
- Do not replace the existing internal HTTPS and mTLS model. SSO should sit on
  top of it.

## Recommended Shape

- Identity provider: Kanidm on `pki`.
- Public issuer URL: one canonical URL, likely `https://id.ihar.dev`.
- Internal/public access: apps and browsers should use the same issuer URL.
- Public ingress: expose the IdP through the existing `beast` public nginx
  entrypoint, with mTLS from `beast` to `pki` like other external services.
- Internal HTTPS: add an internal HTTPS service for the IdP on `pki` with an
  internal PKI certificate.
- Package detail: set `services.kanidm.package` to
  `pkgs.kanidmWithSecretProvisioning_1_10` because the pinned nixpkgs has a
  removed default `pkgs.kanidm` alias.

## Identity Model

Use groups as the stable authorization contract. Users belong to groups;
services consume group claims.

Initial groups:

- `sso-admins`: administer the identity provider itself.
- `infra-admins`: admin-only infra tools such as the *arr services and SABnzbd.
- `grafana-admins`: Grafana server/org admins.
- `grafana-viewers`: Grafana read-only users.
- `paperless-admins`: Paperless staff/admin users.
- `paperless-users`: Paperless regular users.
- `vikunja-users`: Vikunja users.
- `ai-users`: Open WebUI users.
- `romm-admins`: RomM admins.
- `romm-editors`: RomM editors.
- `romm-viewers`: RomM viewers.
- `media-admins`: reserved for Jellyfin/Audiobookshelf later.
- `media-users`: reserved for Jellyfin/Audiobookshelf later.

Initial users:

- `ihar`: admin across SSO, infra, Grafana, Paperless, Vikunja, AI, and RomM.
- `kasia`: likely Paperless, Vikunja, AI, and selected media groups.
- Add more users only with a clear group assignment and service need.

## Service Buckets

### Native OIDC First

These should use application-native OIDC rather than proxy-only auth:

- Grafana (`grafana.home.arpa`)
  - Configure Generic OAuth.
  - Map `grafana-admins` to Admin.
  - Map `grafana-viewers` to Viewer.
  - Keep local admin credentials as break-glass.
- Vikunja (`vi.ihar.dev`)
  - Configure `auth.openid`.
  - Initially keep local auth enabled for migration.
  - Disable local auth only after existing users are linked or recreated.
- Paperless (`papers.ihar.dev`)
  - Configure django-allauth OIDC through
    `PAPERLESS_SOCIALACCOUNT_PROVIDERS`.
  - Decide whether signup creates regular users only, with admin/staff still
    bootstrapped locally.
  - Keep Paperless API token for automation.
- Open WebUI (`ai.ihar.dev`)
  - Configure OIDC env vars.
  - Keep `ENABLE_PERSISTENT_CONFIG = False`.
  - Start with password auth enabled until OIDC login succeeds.
  - Disable password auth only after a break-glass path is documented.
- RomM (`game.ihar.dev`)
  - Configure `OIDC_ENABLED`.
  - Use role claims for `romm-admins`, `romm-editors`, and `romm-viewers`.
  - Disable username/password login only after OIDC roles are verified.

### Native Or App-Level Later

- Audiobookshelf (`au.ihar.dev`)
  - Has OIDC support, but the current NixOS module exposes only basic service
    options.
  - Determine whether settings can be made declarative through config files,
    database/API bootstrap, or a local module extension.
- Jellyfin (`jf.ihar.dev`)
  - Handle in a dedicated migration.
  - Avoid proxy-only auth as the final solution because native/mobile/TV clients
    and per-user library permissions need app-level identity.
  - Review plugin health before committing to a Jellyfin SSO path.

### Proxy-Gated Admin/Internal Apps

These are good candidates for `oauth2-proxy` plus nginx `auth_request`.
The app keeps its own auth model or no auth; nginx enforces SSO before traffic
reaches it.

- Radarr
- Sonarr
- Lidarr
- Bazarr
- Prowlarr
- SABnzbd
- Glance/startpage, if desired
- Letterboxd Radarr bridge, if it should not be open on LAN

Initial proxy access policy:

- Require `infra-admins` for all admin/download-management tools.
- Consider a weaker `home-users` group only for read-only landing pages such as
  Glance if non-admin users need it.

Deferred:

- Transmission: no change in this rollout.

Needs separate assessment:

- Seerr (`js.ihar.dev`): verify current auth capabilities in `seerr-team/seerr`.
- Aurral (`mu.ihar.dev`): decide whether it should be public, native-auth, or
  proxy-gated.
- Shelfmark (`shelf.ihar.dev`): decide whether it should be public,
  native-auth, or proxy-gated.
- LiteLLM gateway (`llm.ihar.dev`): API-key based service; do not blindly put a
  browser SSO gate in front of API clients without checking clients and
  intended usage.

## Ordered Work Items

### 1. Prepare Inventory And Naming

- [ ] Choose canonical IdP public host, probably `id.ihar.dev`.
- [ ] Choose internal service name, probably `id.home.arpa` or
      `kanidm.home.arpa`.
- [ ] Add IdP to `lib/inventory.nix` as an external service owned by `pki`.
- [ ] Add `id` or `kanidm` as a local DNS alias for the `pki` host.
- [ ] Decide whether the user-facing display name is `SSO`, `Identity`, or
      `Kanidm`.

### 2. Provision PKI And Ingress

- [ ] Add `host.internalHttps.services.<idp>` on `pki`.
- [ ] Issue internal HTTPS cert for the IdP service with
      `nix run .#issue-internal-service-cert -- --host pki --service <idp>`.
- [ ] Add public ingress on `beast` for `id.ihar.dev`.
- [ ] Add an mTLS client identity on `beast` for the IdP upstream.
- [ ] Issue any needed mTLS client/server certs.
- [ ] Confirm public and internal paths both resolve to the same OIDC issuer
      URL.

### 3. Add Kanidm Service

- [ ] Add `nixos/pki/sso.nix`.
- [ ] Import it from `nixos/pki/default.nix`.
- [ ] Set `services.kanidm.server.enable = true`.
- [ ] Set `services.kanidm.package = pkgs.kanidmWithSecretProvisioning_1_10`.
- [ ] Bind Kanidm to loopback or a private listener behind nginx.
- [ ] Set Kanidm `origin` to the canonical issuer URL.
- [ ] Configure TLS settings as required by the module, using the internal HTTPS
      service or direct service TLS based on the final module shape.
- [ ] Enable Kanidm online backups.
- [ ] Add sops secrets for Kanidm admin/idm admin bootstrap passwords.
- [ ] Add monitoring probes and dashboard/rule follow-ups.

### 4. Declare Users And Groups

- [ ] Add declarative Kanidm groups listed in this document.
- [ ] Add `ihar` with admin groups.
- [ ] Add `kasia` with initial non-admin groups.
- [ ] Decide which fields are required for every person:
      display name, legal name, primary email, and optional extra mail.
- [ ] Decide whether group membership is strictly declarative or partially
      managed in the IdP UI. Prefer declarative for the initial rollout.

### 5. Create OIDC Clients In Kanidm

Create one OAuth/OIDC client per native app:

- [ ] `grafana`
- [ ] `vikunja`
- [ ] `paperless`
- [ ] `open-webui`
- [ ] `romm`
- [ ] later: `audiobookshelf`
- [ ] later: `jellyfin`

For each client:

- [ ] Add a unique sops client secret.
- [ ] Set exact redirect URL(s).
- [ ] Set `originLanding`.
- [ ] Prefer short usernames if supported and useful.
- [ ] Expose `openid`, `profile`, `email`, and group/role claims.
- [ ] Restrict scopes or login eligibility by group where practical.

### 6. Configure Native OIDC Apps

Roll out one app at a time. For each app:

- [ ] Add app OIDC settings.
- [ ] Add/reuse sops client secret.
- [ ] Keep local auth enabled for the first deployment.
- [ ] Deploy.
- [ ] Log in as `ihar`.
- [ ] Log in as a non-admin user if applicable.
- [ ] Verify role/group mapping.
- [ ] Verify logout behavior.
- [ ] Verify API keys and automation still work.
- [ ] Decide whether to disable local password auth.
- [ ] Document the rollback path.

Suggested order:

- [ ] Grafana
- [ ] Vikunja
- [ ] Open WebUI
- [ ] Paperless
- [ ] RomM

### 7. Add `oauth2-proxy` For Admin Apps

Start with `srvarr`, because most proxy-gated services live there.

- [ ] Add an OAuth client for `srvarr-admin-apps` in Kanidm.
- [ ] Add sops secrets for oauth2-proxy client secret and cookie secret.
- [ ] Enable `services.oauth2-proxy` on `srvarr`.
- [ ] Set provider to OIDC and issuer to the canonical Kanidm issuer.
- [ ] Set groups claim handling.
- [ ] Enable `services.oauth2-proxy.nginx`.
- [ ] Protect nginx vhosts by their actual attr names, for example
      `internal-https-radarr`, not just `radarr.home.arpa`.
- [ ] Start with one low-risk vhost.
- [ ] Verify login, group denial, and logout.
- [ ] Expand to the rest of the admin apps.

Initial proxy-gated order:

- [ ] Radarr
- [ ] Sonarr
- [ ] Lidarr
- [ ] Prowlarr
- [ ] Bazarr
- [ ] SABnzbd
- [ ] Glance, if desired
- [ ] Letterboxd Radarr bridge, if desired

Do not include:

- [ ] Transmission

### 8. Review Public Apps That Are Not Covered

- [ ] Decide Seerr auth path.
- [ ] Decide Aurral auth path.
- [ ] Decide Shelfmark auth path.
- [ ] Decide LiteLLM gateway auth/API-key path.
- [ ] Update this document with the chosen path before implementing those.

### 9. Monitoring And Operations

- [ ] Add a blackbox probe for `id.ihar.dev`.
- [ ] Add internal probe for the IdP backend.
- [ ] Add alert rules for IdP unavailability.
- [ ] Add certificate expiry coverage for IdP public and internal certs.
- [ ] Add backup coverage for Kanidm state.
- [ ] Add a recovery note for IdP admin password and local break-glass app
      accounts.

### 10. Cleanup After Successful Migration

Do this only after native/proxy auth is stable.

- [ ] Remove unnecessary declarative local user passwords from apps that no
      longer need them.
- [ ] Keep app admin passwords only where they are intentional break-glass
      paths.
- [ ] Keep API tokens for automation.
- [ ] Update service READMEs or comments where login behavior changes.
- [ ] Add a short SSO section to `nixos/pki/README.md`.

## Validation Checklist

For each migrated service:

- [ ] New session redirects to Kanidm.
- [ ] Existing valid SSO session reaches the app without another password.
- [ ] User without the required group is denied.
- [ ] Admin user has expected privileges.
- [ ] Non-admin user has expected privileges.
- [ ] Logout does not leave an unexpected active app session.
- [ ] App API tokens and automation still work.
- [ ] Mobile/native clients are tested where relevant.
- [ ] Local break-glass login still works if intentionally retained.

## Rollback Principles

- Keep local app login enabled until the replacement works.
- Keep service-specific sops secrets until after a cleanup pass.
- Change one service at a time.
- Prefer adding OIDC alongside existing auth, then tightening later.
- For proxy-gated apps, rollback is removing nginx auth_request or removing the
  vhost from `services.oauth2-proxy.nginx.virtualHosts`.

## Open Questions

- Exact canonical IdP hostname: `id.ihar.dev`, `sso.ihar.dev`, or another name.
- Whether Kanidm should be directly TLS-serving behind nginx or plain loopback
  behind the internal HTTPS service.
- Whether all household users should have email addresses in Kanidm.
- Whether Paperless admin/staff status should be group-driven or remain
  declaratively bootstrapped in Paperless.
- Whether Open WebUI should auto-approve `ai-users` or leave first login
  pending.
- Whether Glance should be open on LAN, restricted to `infra-admins`, or
  available to a broader `home-users` group.
