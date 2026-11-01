# Vikunja provisioning

`vikunja-provision` reconciles a tracked bot declaration, its project shares, and
a scoped MCP token against Vikunja's v2 API. Use Vikunja 2.7.1 or newer for the
corrected API-token permission checks.

Declarations live in the service host's Nix configuration under
`host.vikunja.bots`. The initial declaration is
[`org/agents`](../../nixos/org/default.nix): `bot-agents`, with read/write access
to `Homelab` and token permissions for reading projects, reading/creating/updating
tasks, and reading/creating comments. Its token expires on November 1, 2027.
Its declared seats are `mair`, `frame`, and `mmini`.

Each bot declares its display name, project grants, and token permissions and
expiry. The username defaults to `bot-<declaration name>` and the token title to
the declaration name. Project grants are keyed by exact title, with permission
`read`, `read-write`, or `admin`. Titles must identify exactly one accessible
project; missing or ambiguous names fail before any provisioning writes.
Token permission names come from the instance's `/api/v2/routes` endpoint.

The bot's `seats` list controls both token distribution and agent configuration.
Each selected seat gets the `vikunja-org-agents` MCP connection in Codex and
Claude, backed by `agents/vikunja/org/agents/authorization` in that host's SOPS
file. The provisioner writes the full `Bearer …` value, without printing it or
placing it in the Nix store. Other bots use their own host and declaration name
in the connection name and secret key.

The flake app generates and bundles the declarations from configured Vikunja
hosts, including each instance's public URL. No separate JSON file is needed.
Preview and apply a declaration by host and bot name:

```sh
nix run .#vikunja-provision -- plan org agents

nix run .#vikunja-provision -- apply org agents
```

Each command prints a login URL on stderr. Open it in a browser on the same
machine, sign in through your normal Vikunja SSO, and return to the terminal.
The signed-in user must own the bot and administer projects whose sharing
changes. OAuth authorization uses PKCE and a temporary loopback callback
listener; no client registration is needed. The user-session and refresh tokens
are not saved. An existing raw user-session JWT can instead be supplied with
`--session-token-file`; the file must be accessible only by its owner. A `tk_`
API token cannot manage bots or mint credentials.

`plan` reads Vikunja and decrypts the selected SOPS files without modifying them.
Both commands print a JSON list of changes without secrets. SOPS access is
checked for every seat before provisioning writes begin; allow the usual age or
Secure Enclave approval prompts. `apply` creates the bot if absent, sets its
display name and active status, and reconciles the declared direct project
shares. Undeclared shares, other bots, and unrelated tokens are preserved.
Removing a project from the declaration does not revoke an earlier share.

The server, bot ID, token ID, raw token, and pending rotation state are stored
together as encrypted JSON at `agents/vikunja/org/agents/credentials` in `org`'s
SOPS file. This record belongs to the service host, independently of which seats
are selected. Decrypted values stay in memory; no local credential file is
needed. An empty lock file in the temporary directory serializes local runs for
the same server and bot. Run provisioning from only one machine at a time.

On apply, the token is also written to each declared seat's encrypted file
through the repository's SOPS library. Matching values are left unchanged.
Writes are sequential and stop at the first failure, reporting which seats are
complete and which remain.

Run the app from this checkout. Review and commit the changed encrypted files,
then deploy the selected seats normally to activate their MCP configuration.
The app does not push or deploy. Removing a seat stops managing its configuration
and secret; it does not erase an earlier secret or revoke a copied shared token.

Repeat applies preserve the token. To change its title, permissions, or expiry,
or to replace lost/revoked credentials, preview and apply with `--rotate-token`.
Rotation saves the replacement in the encrypted record, updates all selected
SOPS files, and only then revokes the previous token. Activate the updated seats
to load the new token. If distribution or revocation fails, the encrypted record
retains the pending rotation: retry `apply` without `--rotate-token` to resume
using the saved replacement. A second rotation is refused while one is pending.
If the initial SOPS save fails, the app attempts to revoke the newly issued token
and keeps the previous credentials. Unrelated duplicate token titles are
rejected rather than choosing a token to revoke.

API writes are not transactional across endpoints. A failed apply may leave a
created bot or updated shares; a later apply reads those resources and resumes.
Keep the encrypted state and seat files together when committing or transferring
changes to another checkout.

Protocol references: [bot accounts](https://vikunja.io/docs/bot-users/),
[API v2](https://vikunja.io/docs/api-v2/), and
[Vikunja's loopback OAuth flow](https://github.com/go-vikunja/vikunja/blob/v2.7.1/veans/internal/auth/oauth.go).
