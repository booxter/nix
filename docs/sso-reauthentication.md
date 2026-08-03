# SSO Reauthentication Contract

This document defines the repository's contract between nginx,
`oauth2-proxy`, browser applications, and synthetic probes when an SSO session
expires. It applies to applications protected by
`host.sso.oauth2ProxyGates` with `authFailureMode = "navigation-aware"`.

This is not a new OAuth or OpenID Connect protocol. It is the local behavior
required to make standards-based sign-in recover safely in applications that
use an authentication proxy.

## Goals

- An expired SSO session must look like an authentication event, not a broken
  backend.
- A normal document navigation may start sign-in automatically.
- A background request must never turn into an HTML login response.
- The proxy must never redirect or replay a state-changing request.
- Applications may restore only explicitly reviewed, read-only user intent.
- Native OIDC applications should use their native refresh and
  reauthentication support instead of this proxy contract.

## Session Boundaries

The system has three independent session layers:

1. The Kanidm login session records whether the browser is signed in to the
   identity provider.
2. The `oauth2-proxy` session records authorization for a protected gate and
   may hold or refresh OIDC tokens through a server-side Redis entry.
3. The application session records any identity, token, or state maintained by
   the application itself.

Expiry at one layer does not imply expiry at the others. Application code must
not infer that its backend is unavailable merely because a proxy session has
expired.

## Proxy Contract

### Authenticated Requests

When `oauth2-proxy` accepts the session, nginx forwards the original request to
the application. The request method and body are unchanged.

The gate may forward reviewed identity headers such as `X-User` or `X-Email`.
Applications must trust those headers only on traffic that can arrive through
the managed proxy path.

### Unauthenticated Document Navigations

nginx may start SSO automatically only when all of these conditions hold:

- the method is `GET` or `HEAD`
- the request is not an HTMX background request
- Fetch Metadata identifies a top-level document navigation with
  `Sec-Fetch-Mode: navigate` and `Sec-Fetch-Dest: document`

For clients that do not send Fetch Metadata, a safe request accepting
`text/html` is treated as a document navigation.

The response redirects to `/oauth2/start` with HTTP 302. The return target is
same-origin and may preserve the requested document path and query string.

### Background And Unsafe Requests

All other failed authentication checks return:

```http
HTTP/1.1 401 Unauthorized
X-SSO-Reauth: 1
Cache-Control: no-store
```

This includes:

- `fetch`, XHR, API, event-stream, script, and WebSocket-related requests
- HTMX background requests
- `POST`, `PUT`, `PATCH`, and `DELETE`, even if they claim to be navigations

The response must not contain a `Location` header. HTMX requests may also
receive `HX-Refresh: true`.

The marker means only that the managed proxy rejected the SSO session. A plain
application-generated 401 without `X-SSO-Reauth: 1` retains its native
meaning.

nginx must remove a spoofed `X-SSO-Reauth` request header and hide that header
from ordinary upstream responses. Only the managed reauthentication path may
emit the marker.

### Session Check

Navigation-aware gates expose `GET /oauth2/session` for same-origin browser
code:

- HTTP 202 means the proxy session is currently valid.
- A marked HTTP 401 means reauthentication is required.
- Both responses use `Cache-Control: no-store`.

This endpoint is advisory. An application must still handle a marked 401 from
the real request because the session can expire between the check and the
request.

## Application Contract

### Detection

Browser code must react only when both conditions are true:

- the response status is 401
- `X-SSO-Reauth` is exactly `1`

Applications must not turn every native 401 into SSO. Doing so can hide real
authorization failures, create login loops, and interfere with application
login or API-token behavior.

Applications with a central HTTP client should implement detection once in
that client. Applications using native form submissions may check
`/oauth2/session` immediately before a submission that cannot survive an SSO
navigation.

### Starting Reauthentication

The application starts reauthentication by navigating the current window to a
fixed, safe, same-origin `GET` entry point. That request is then classified as
a document navigation by nginx.

The application must not:

- send the rejected request body to `/oauth2/start`
- put saved form fields, credentials, tokens, or private query text in the
  login or return URL
- use the rejected request's unsafe method for the SSO entry point
- construct a cross-origin return target

An application-specific reauthentication endpoint is acceptable when it is a
safe `GET`, remains available after upgrades, and returns the user to a
validated same-origin location. Navigating to a known application document,
such as `/`, is also acceptable.

### Restoring User Intent

Automatic replay is forbidden by default. It is allowed only for an operation
that has been reviewed as read-only and explicitly allowlisted by the
application integration.

Examples that may be allowlisted:

- submitting a search, even when the upstream application represents it as
  `POST`
- restoring filters or pagination that do not mutate server state

Operations that must not be replayed automatically include:

- account or permission changes
- uploads, deletions, downloads with side effects, or media-management actions
- API mutations and administrative forms
- any operation whose idempotence or side effects are uncertain

After reauthentication, a non-replayable operation should return the user to a
safe page and ask them to retry. This preserves fresh user intent.

When a read-only operation is replayed, pending state must:

- use `sessionStorage`, not persistent cross-session storage
- contain only the minimum fields required for the reviewed operation
- record the expected origin, path, method, and a short expiry time
- be rejected if malformed, stale, cross-origin, or for an unexpected path
- be consumed once and cleared before or during replay
- have a loop guard so repeated authentication failures do not navigate
  forever

Multiple simultaneous marked failures must converge on one reauthentication
flow rather than opening multiple windows or repeatedly replacing the page.

## Why The Proxy Does Not Use 307

HTTP 307 preserves the original method and body. If the proxy redirects every
authentication failure with 307, an expired-session `POST` is sent to the SSO
entry point as a `POST` rather than becoming a safe navigation.

That creates two classes of risk:

- sensitive request bodies can reach authentication endpoints, intermediary
  logs, or error handlers that were never intended to receive them
- a mutation can be retried after an authentication round trip without a new
  user decision, causing duplicate or stale actions

The proxy therefore converts only safe document requests into sign-in
navigations. Application code has enough semantic knowledge to decide whether
a particular read-only intent can be restored.

## Redis-Backed Proxy Sessions

Use the gate's `sessionRefresh` configuration when `oauth2-proxy` must retain
server-side session state and periodically refresh OIDC tokens. The configured
Redis instance must:

- listen only on the intended local or authenticated service path
- persist its dataset across normal service and host restarts
- start before `oauth2-proxy`
- use an eviction policy compatible with session TTLs

A persisted Redis restart should not log users out. If a Redis session entry
is lost, the browser cookie is insufficient and the next request follows this
reauthentication contract. The user may pass through SSO again, but the
application must not appear to have a dead backend.

Redis is not an application session store and is not required merely because
an application supports native OIDC.

## Native OIDC Applications

Applications with suitable native OIDC support should use it directly. Their
native implementation owns token refresh, expired-session detection, login
launch, callback handling, and native or mobile-client compatibility.

The expected browser behavior is still graceful recovery: an expired native
session should launch SSO or present an obvious sign-in action rather than a
generic backend error. Validation is application-specific because the proxy
marker and `/oauth2/session` endpoint do not apply.

Audiobookshelf is currently in this category. Local login may remain available
when required for rollback or native-client compatibility.

## Required Tests

### Shared Proxy Tests

The NixOS nspawn test must cover:

- a valid session reaching the backend
- a safe document navigation receiving a 302 sign-in redirect
- a background request receiving the marked, non-cacheable 401
- every unsafe method receiving 401 without a redirect or body replay
- HTMX and non-document browser transports
- valid and expired `/oauth2/session` responses
- removal of spoofed markers and preservation of native application 401s

The canonical test is
[`tests/nixos/oauth2-proxy-gate.nix`](../tests/nixos/oauth2-proxy-gate.nix).

### Application Tests

Application-side backports must run tests in the package `checkPhase`. Tests
should cover, as applicable:

- strict marker detection
- preservation of native application 401 behavior
- a fixed safe reauthentication URL
- absence of private saved data from the login URL
- validation and expiry of pending state
- one-time replay of each allowlisted read-only operation
- refusal to replay mutations or unknown operations
- loop prevention

### Synthetic Probes

A synthetic probe modeling a browser navigation must send at least:

```http
Accept: text/html
Sec-Fetch-Mode: navigate
Sec-Fetch-Dest: document
```

Discovery, JWKS, token, userinfo, and other protocol/API requests must retain
API request semantics. A green synthetic probe proves that the navigation and
OIDC path work; it does not replace browser testing of application-specific
replay behavior.

### Canary Browser Checks

For each application:

1. Confirm normal use with a valid proxy and application session.
2. Delete only that gate's `oauth2-proxy` cookie from an already loaded tab.
3. Trigger a background read and confirm graceful SSO recovery.
4. Delete the cookie again and refresh the document; confirm normal SSO and
   return.
5. Exercise every allowlisted read-only replay, including form submissions.
6. Confirm a representative mutation is not silently replayed.
7. When Redis is used, verify a persisted Redis restart retains the session.
8. Check the synthetic metric and related alerts after deployment.

## Adoption Procedure

Migrate one gate at a time:

1. Inspect the application's request and session code. Inventory background
   transports, native 401 handling, forms, and mutations.
2. Decide whether native OIDC or the proxy contract is appropriate.
3. Identify any read-only operations that require restoration. Everything else
   remains non-replayable.
4. Implement and test application handling before, or in the same deployment
   as, `authFailureMode = "navigation-aware"`.
5. Run `nix fmt`, package checks, and the shared NixOS proxy test as relevant.
6. Run `deploy --local --test` and inspect every unit that would stop, restart,
   reload, or start.
7. Deploy a canary and complete the browser checks above.
8. Add or update a synthetic navigation probe and verify alert recovery.
9. Record the result in the adoption status below before starting the next
   gate.

Do not enable navigation-aware failures for a collection of unrelated apps
until every protected frontend has been inspected. A shared gate and cookie
make the entire collection one rollout unit.

## Adoption Status

- Aurral: adopted and canary-tested. It uses `oauth2-proxy` with Redis-backed
  refresh and an application reauthentication route. The proxy does not replay
  requests.
- SearXNG: adopted, browser-tested, and synthetically probed. Its marked-401
  handler may replay only the allowlisted search POST.
- Audiobookshelf: native OIDC is configured with automatic OIDC launch. The
  proxy contract does not apply.
- DeGoog (`goo`): adopted and browser-tested. Its fetch and EventSource
  handlers recover from marked failures and restore only reviewed navigation
  or search state.
- Telegram Archive (`tg`): adopted and browser-tested. Its fetch interceptor
  restores only the selected chat or topic, while WebSocket reconnects probe
  the proxy session first.
- Paperless-GPT: legacy proxy redirect; pending inspection and adoption.
- Jellystat (`jfstat`): legacy proxy redirect; pending inspection and adoption.
- WatchState: legacy proxy redirect; pending inspection and adoption.
- `srvarr-admin-apps`: adopted and browser-tested across Bazarr, Houndarr,
  Lidarr, Prowlarr, Radarr, SABnzbd, Sonarr, and Transmission. Marked failures
  start a safe top-level login without replaying rejected requests. Houndarr
  relies on its vendored HTMX refresh behavior; the other frontends carry
  release patches with package checks.

Jellyfin is not protected by these gates and must not be restarted merely to
adopt this contract in another application on `beast`.

## Implementation References

- Shared gate:
  [`nixos/_mixins/sso-oauth2-proxy-gate.nix`](../nixos/_mixins/sso-oauth2-proxy-gate.nix)
- Shared proxy test:
  [`tests/nixos/oauth2-proxy-gate.nix`](../tests/nixos/oauth2-proxy-gate.nix)
- Synthetic probe:
  [`nixos/pki/pkgs/oidc-synthetic-probe/`](../nixos/pki/pkgs/oidc-synthetic-probe/)
- Aurral reauthentication backport:
  [`nixos/srvarr/pkgs/aurral/keep-proxy-reauth-upgrade-route.patch`](../nixos/srvarr/pkgs/aurral/keep-proxy-reauth-upgrade-route.patch)
- SearXNG reauthentication backport:
  [`overlays/searxng-load-sso-reauth-script.patch`](../overlays/searxng-load-sso-reauth-script.patch)
- DeGoog reauthentication backport:
  [`nixos/org/pkgs/degoog/sso-reauthentication.patch`](../nixos/org/pkgs/degoog/sso-reauthentication.patch)
- Telegram Archive reauthentication backport:
  [`nixos/org/pkgs/telegram-archive/sso-reauthentication.patch`](../nixos/org/pkgs/telegram-archive/sso-reauthentication.patch)
