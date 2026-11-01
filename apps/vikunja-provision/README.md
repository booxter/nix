# Vikunja provisioning

`vikunja-provision` reconciles one bot, its declared project shares, and a scoped
MCP token against Vikunja's v2 API. Use Vikunja 2.7.1 or newer for the corrected
API-token permission checks.

The declaration is JSON and contains no credentials. For example:

```json
{
  "server": "https://vi.ihar.dev",
  "bot": {
    "username": "bot-agents",
    "name": "Coding agents"
  },
  "projects": [
    { "id": 42, "permission": 1 }
  ],
  "token": {
    "title": "agents",
    "permissions": {
      "mcp": ["access"],
      "projects": ["read_all", "read_one"],
      "tasks": ["read_all", "read_one", "create", "update"],
      "tasks_comments": ["read_all", "create"]
    },
    "expires_at": "2027-11-01T00:00:00Z"
  }
}
```

Replace the project ID and choose an expiry date. Project permissions are
`0` (read), `1` (read/write), or `2` (admin). The signed-in user must own the bot
and administer each project whose sharing changes. Token permission names come
from the instance's `/api/v2/routes` endpoint.

Preview and apply the same declaration:

```sh
nix run .#vikunja-provision -- plan \
  --config ./bot.json \
  --credentials-file ~/.config/vikunja/agents.json

nix run .#vikunja-provision -- apply \
  --config ./bot.json \
  --credentials-file ~/.config/vikunja/agents.json
```

Each command prints a login URL on stderr. Open it in a browser on the same
machine, sign in through your normal Vikunja SSO, and return to the terminal.
OAuth authorization uses PKCE and a temporary loopback callback listener; no
client registration is needed. The user-session and refresh tokens are not saved.
An existing raw user-session JWT can instead be supplied with
`--session-token-file`; the file must be accessible only by its owner. A `tk_`
API token cannot manage bots or mint credentials.

`plan` reads Vikunja without modifying it. Both commands print a JSON list of
changes without secrets. `apply` creates the bot if absent, sets its display name
and active status, and reconciles the declared direct project shares. Undeclared
shares, other bots, and unrelated tokens are preserved. Removing a project from
the declaration does not revoke an earlier share.

The credentials file contains the server, bot ID, token ID, and raw token. It is
written atomically with mode `0600`; keep it outside the repository. Preserve
this file between runs. A sibling lock file serializes commands using the same
credentials path. The saved token can later be distributed through the repo's
SOPS helpers; this app does not modify SOPS files or agent configuration.

Repeat applies preserve the token. To change its title, permissions, or expiry,
or to replace lost/revoked credentials, preview and apply with `--rotate-token`.
Rotation saves the replacement before revoking the previous token. If saving
fails, the app attempts to revoke the newly issued token and keeps the previous
credentials. If revocation fails, it reports the token ID requiring cleanup.
Duplicate token titles are rejected rather than choosing a token to revoke.

API writes are not transactional across endpoints. A failed apply may leave a
created bot or updated shares; a later apply reads those resources and resumes.
Use a single credentials path for each declared token.

Protocol references: [bot accounts](https://vikunja.io/docs/bot-users/),
[API v2](https://vikunja.io/docs/api-v2/), and
[Vikunja's loopback OAuth flow](https://github.com/go-vikunja/vikunja/blob/v2.7.1/veans/internal/auth/oauth.go).
