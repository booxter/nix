# SSO/OIDC Rollout Plan

Working document for moving human-facing services in this fleet to one
identity source and a consistent SSO policy.

## Goal

- Run a self-hosted OIDC identity provider on `pki`.
- Define users and groups once.
- Use native OIDC in applications that support it.
- Use `oauth2-proxy` plus nginx `auth_request` for admin tools that do not
  support OIDC.
- Manage users, groups, OIDC clients, and app SSO settings declaratively from
  this repository.
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
- Do not add repo helper apps speculatively. Add one only when a concrete,
  non-obvious, multi-step operational workflow proves it would reduce risk or
  repeated manual work.

## Recommended Shape

- Identity provider: Kanidm on `pki`.
- Display name: SSO.
- Public issuer URL: `https://id.ihar.dev`.
- Internal service name: use `id.home.arpa` where an internal name is needed.
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
  The first declarative pass places `ihar` in the fleet-level `sso-admins`
  group, but does not yet mutate Kanidm built-in admin groups such as
  `idm_admins`; `admin` and `idm_admin` remain the break-glass IdP admin path
  until a deliberate admin-delegation step is added.
- `kasia`: non-admin. Primary email is `kasia.bondarava@gmail.com`. Initial
  likely groups are Paperless, Vikunja, AI, and selected media groups.
- Add more users only with a clear group assignment and service need.

Person records should stay practical: account name, display name, primary
email, optional extra mail, and groups. Use account-style display names such as
`ihar` and `kasia`; do not model legal names unless there is a concrete service
need.

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
  - Migrate the current declarative bootstrap users toward OIDC-backed users.
  - Prefer group-driven Paperless staff/admin assignment if Paperless can be
    made to support it cleanly; otherwise keep a small declarative app-local
    bootstrap only for staff/admin state.
  - Keep Paperless API token for automation.
- Open WebUI (`ai.ihar.dev`)
  - Configure OIDC env vars.
  - Keep `ENABLE_PERSISTENT_CONFIG = False`.
  - Auto-approve users in `ai-users`.
  - Start with password auth enabled until OIDC login and `ai-users`
    auto-approval succeed.
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
- Letterboxd Radarr bridge, if it should not be open on LAN

Initial proxy access policy:

- Require `infra-admins` for all admin/download-management tools.

Deferred:

- Transmission: no change in this rollout.
- Glance: do not include in the initial proxy-gating work.

Needs separate assessment:

- Seerr (`js.ihar.dev`): verify current auth capabilities in `seerr-team/seerr`.
- Aurral (`mu.ihar.dev`): decide whether it should be public, native-auth, or
  proxy-gated.
- Shelfmark (`shelf.ihar.dev`): decide whether it should be public,
  native-auth, or proxy-gated.
- LiteLLM gateway (`llm.ihar.dev`): API-key based service; do not blindly put a
  browser SSO gate in front of API clients without checking clients and
  intended usage.

## Rollout Workflow

- Work in small stages.
- Each stage should be one focused local commit.
- Codex patches the repo and runs local checks.
- The operator deploys the committed stage.
- Codex then checks the live result over the appropriate service URLs, logs, or
  SSH commands.
- Do not proceed to the next stage until the current stage has a clear live
  result and rollback path.
- Preserve existing login paths while introducing SSO. Tighten or remove local
  login only in a later stage after the SSO path has been verified.
- If a stage touches an app login flow, explicitly test both the old login path
  and the new SSO path before moving on.

## Current Status

- `id.ihar.dev` is live as Kanidm.
- `pki` serves `id.home.arpa` through the internal HTTPS module with mTLS
  enforced.
- `beast` serves public `id.ihar.dev` and proxies to `pki` over the existing
  external-service mTLS/stunnel pattern.
- Initial placeholder path verified on 2026-06-24:
  - `https://id.ihar.dev/healthz` returns the placeholder response.
  - `http://id.ihar.dev/healthz` redirects to HTTPS.
  - `id.home.arpa` rejects requests without a client cert.
  - `id.home.arpa` accepts requests with an internal PKI client cert.
- First Kanidm deploy attempt on 2026-06-24 partially activated: Kanidm started
  and provisioned successfully, but nginx failed its pre-start config test
  because `proxy_http_version` was emitted twice. The follow-up fix removes the
  redundant Kanidm-specific directive and keeps the shared internal HTTPS module
  defaults.
- Verified on 2026-06-24 after the follow-up fix:
  - `kanidm.service` is active.
  - `nginx.service` is active.
  - `https://id.ihar.dev/status` returns `true`.
  - `https://id.ihar.dev/ui/login` serves the Kanidm login UI.
  - `id.home.arpa/status` rejects requests without a client certificate.
  - `id.home.arpa/status` returns `true` with an internal PKI client
    certificate.
- Verified on 2026-06-24 after deploying `fana`:
  - `prometheus.service`, `prometheus-blackbox-exporter.service`,
    `grafana.service`, and `nginx.service` are active.
  - Prometheus scrapes SSO split-DNS and public-WAN blackbox targets using
    `/status`.
  - `probe_success{service="id"}` is `1` for split-DNS, public-WAN, and public
    DNS probes.
  - `probe_http_status_code{service="id"}` is `200` for split-DNS and
    public-WAN probes.
  - No active Prometheus alerts were present for `service="id"` or
    `public_host="id.ihar.dev"`.
  - Public TLS expiry metrics exist for SSO through blackbox SSL probes.
  - Internal PKI expiry metrics did not show an `id` internal HTTPS certificate
    series after several scrape intervals. This is not just Prometheus scrape
    lag: `pki-status-export` uses `--base-branch master`, so the series should
    appear after this branch lands on `master`, unless that exporter workflow is
    changed.
- Current implementation stage: exercise the Kanidm enrollment/reset email
  path.
- Mail sender is deployed on `pki`. It reuses the existing Gmail SMTP sender
  details from Vikunja by copying that app password into `pki` as
  `kanidm/mailer/password`. The `mail-sender` Kanidm service account and
  read-write API token are ensured by a `pki` oneshot bootstrap service,
  because Kanidm API tokens are generated by the server and cannot be
  predeclared as ordinary Nix data.
- Verify OIDC discovery once the first app client exists.

## Ordered Work Items

### 1. Prepare Inventory And Naming

- [x] Choose canonical IdP public host: `id.ihar.dev`.
- [x] Choose display name: SSO.
- [x] Choose internal service name: `id.home.arpa` if an internal name is
      needed.
- [x] Add IdP to `lib/inventory.nix` as an external service owned by `pki`.
- [x] Add `id` as a local DNS alias for the `pki` host if `id.home.arpa` will
      be served directly on LAN.

### 2. Provision PKI And Ingress

- [x] Add `host.internalHttps.services.<idp>` on `pki`.
- [x] Issue internal HTTPS cert for the IdP service with
      `nix run .#issue-internal-service-cert -- --host pki --service <idp>`.
- [x] Add public ingress on `beast` for `id.ihar.dev`.
- [x] Add an mTLS client identity on `beast` for the IdP upstream.
- [x] Issue any needed mTLS client/server certs.
- [x] Confirm public and internal paths both reach the IdP endpoint.
- [ ] Confirm public and internal paths both use the same OIDC issuer URL after
      Kanidm is enabled.

### 3. Add Kanidm Service

- [x] Add `nixos/pki/id.nix` for the identity service.
- [x] Import it from `nixos/pki/default.nix`.
- [x] Set `services.kanidm.server.enable = true`.
- [x] Set `services.kanidm.package = pkgs.kanidmWithSecretProvisioning_1_10`.
- [x] Bind Kanidm to loopback behind nginx.
- [x] Set Kanidm `origin` to the canonical issuer URL.
- [x] Configure TLS settings required by the module.
- [x] Enable Kanidm online backups.
- [x] Add sops secrets for Kanidm admin/idm admin bootstrap passwords.
- [x] Deploy Kanidm on `pki`.
- [x] Verify `kanidm.service` is active.
- [x] Verify `https://id.ihar.dev/status` returns `true`.
- [x] Verify `id.home.arpa` still requires client certs.
- [ ] Add monitoring dashboard/rule follow-ups.

### 4. Declare Users And Groups

- [x] Add SSO groups and users to `lib/inventory.nix`.
- [x] Map inventory SSO groups and users into Kanidm provisioning on `pki`.
- [x] Add declarative Kanidm groups listed in this document.
- [x] Add `ihar` with fleet-level admin groups.
- [x] Set `ihar` primary email to `ihar.hrachyshka@gmail.com`.
- [x] Add `kasia` with initial non-admin groups.
- [x] Set `kasia` primary email to `kasia.bondarava@gmail.com`.
- [x] Decide which fields are required for every person: account name,
      account-style display name, primary email, optional extra mail, and
      groups.
- [x] Decide whether group membership is strictly declarative or partially
      managed in the IdP UI: strictly declarative from Nix config.
- [x] Deploy initial Kanidm users and groups on `pki`.
- [x] Verify `ihar` and `kasia` person records exist.
- [x] Verify declared group memberships exist.
- [ ] Decide whether to delegate Kanidm built-in admin rights to `sso-admins`
      now or keep using `admin`/`idm_admin` as the IdP admin path.
- [ ] Generate initial enrollment/reset path for `ihar` and `kasia`.

Live verification on `pki` confirmed `kanidm.service` and `nginx.service` are
active, `https://id.ihar.dev/status` returns `true`, both person records exist,
`kasia` has `kasia.bondarava@gmail.com`, and declared group memberships match
the inventory state.

### 4a. Configure Outgoing Email And Enrollment

- [x] Add `ihar.hrachyshka@gmail.com` to the `ihar` Kanidm person record.
- [x] Copy the existing Vikunja Gmail SMTP app password into `pki` as
      `kanidm/mailer/password`.
- [x] Add `nixos/pki/pkgs/kanidm-mail-sender-bootstrap` as the host-local
      bootstrap helper.
- [x] Configure `kanidm-mail-sender-bootstrap.service` to ensure the
      `mail-sender` service account, `idm_message_senders` membership, and
      local API token file.
- [x] Configure `kanidm-mail-sender.service` to send as
      `ihar.hrachyshka@gmail.com` through `smtp.gmail.com:587`.
- [x] Deploy the mail sender stage on `pki`.
- [x] Verify `kanidm-mail-sender-bootstrap.service` succeeds.
- [x] Verify `kanidm-mail-sender.service` is active.
- [x] Add `nix run .#reset-oidc -- <user-id> [email]` for issuing
      enrollment/reset emails through `pki`.
- [ ] Generate enrollment/reset emails for `ihar` and `kasia`.

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

Paperless-specific work:

- [ ] Replace the current local password bootstrap with OIDC-backed login where
      possible.
- [ ] Keep only the minimal Paperless-local declarative bootstrap needed for
      API tokens and staff/admin state.

Open WebUI-specific work:

- [ ] Configure auto-approval for users carrying the `ai-users` group.
- [ ] Verify a user without `ai-users` is not approved.

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
- [ ] Letterboxd Radarr bridge, if desired

Do not include:

- [ ] Transmission
- [ ] Glance

### 8. Review Public Apps That Are Not Covered

- [ ] Decide Seerr auth path.
- [ ] Decide Aurral auth path.
- [ ] Decide Shelfmark auth path.
- [ ] Decide LiteLLM gateway auth/API-key path.
- [ ] Update this document with the chosen path before implementing those.

### 9. Monitoring And Operations

- [x] Add a blackbox probe for `id.ihar.dev`.
- [ ] Add internal probe for the IdP backend.
- [x] Confirm existing service-probe alert rules cover IdP unavailability.
- [x] Confirm public TLS expiry coverage for `id.ihar.dev`.
- [ ] Confirm internal `id` certificate expiry appears in PKI inventory metrics
      after this branch lands on `master`, or adjust `pki-status-export` to
      inspect the deployed branch.
- [ ] Add backup coverage for Kanidm state.
- [ ] Add a recovery note for IdP admin password and local break-glass app
      accounts.

### 9a. Repo Helper Apps Decision Rule

Do not build helper apps just in case. Most SSO work should stay in ordinary
declarative Nix modules, sops secrets, existing PKI helpers, and existing deploy
flows.

A repo-side `nix run .#...` helper is worth considering only if a real workflow
becomes non-obvious, multi-step, and likely to be repeated. Current helpers:

- `nix run .#reset-oidc -- <user-id> [email]`: issue a Kanidm
  enrollment/reset email through `pki` with the standard TTL.

Possible future examples:

- A validation command that catches mismatched Kanidm clients, redirect URIs,
  group claims, and service declarations before deploy.
- A live post-deploy probe that checks the IdP discovery document and selected
  app callback URLs.
- A secret-preparation helper only if client/cookie secret handling becomes
  error-prone across many services.

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
- Keep each stage as a separate commit so it can be reviewed, deployed, checked,
  and reverted independently.
- Prefer adding OIDC alongside existing auth, then tightening later.
- For proxy-gated apps, rollback is removing nginx auth_request or removing the
  vhost from `services.oauth2-proxy.nginx.virtualHosts`.

## Open Questions

- Whether Kanidm should be directly TLS-serving behind nginx or plain loopback
  behind the internal HTTPS service.
- Whether `id.home.arpa` is needed as a user-facing LAN name, or only as an
  internal service/backend name.
- Whether Paperless admin/staff status can be cleanly group-driven or must
  retain a small declarative app-local bootstrap.
- Whether any concrete SSO workflow becomes complex enough to justify a repo
  helper app.
