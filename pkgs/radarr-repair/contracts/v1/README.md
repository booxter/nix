# Radarr repair protocol version 1

These schemas are the canonical wire contract between the deterministic
`radarr-repair` controller and the `radarr-repair-planner`. They use JSON Schema
draft 2020-12 and do not depend on external schema resources.
Language-specific wire models are derived from these schemas during Nix builds;
generated source is not maintained in the repository.

The controller sends normalized, bounded evidence rather than raw Radarr,
Transmission, torrent, or `ffprobe` responses. All externally sourced text is
untrusted data. Absolute paths, credentials, tracker announce URLs, passkeys,
magnet links, and raw diagnostic output are outside the protocol.

## Identity

`case_id` is `sha256:` followed by the lowercase SHA-256 digest of the RFC 8785
canonical JSON representation of the repair case after removing `case_id` and
`observed_at`. A new observation time alone therefore does not create a new
case, while changed planning evidence does.

File, capability, and evidence identifiers are opaque to the planner. A
decision may only reference identifiers present in its request. JSON Schema
validates their representation; the controller independently validates
membership, the echoed case ID, and all execution policy.

Paths are arrays of individual relative components. Components cannot be
empty, `.`, `..`, contain path separators, or contain control characters. The
protocol has no field capable of designating an absolute path. The controller
must also redact paths and secrets embedded in human-readable source messages;
JSON Schema cannot infer their meaning from prose.

## Decisions

Version 1 offers two actions:

- `no_repair` records a bounded reason, missing-evidence categories, evidence
  references, and explanation.
- `join_parts_v1` selects one controller-advertised capability and orders two
  or more eligible file identifiers.

The planner cannot select an output path or name, container, executable, or
command argument. A schema-valid join decision is still inert until the
controller validates identifier membership, feasibility, current source
fingerprints, and execution policy.

New optional evidence requires a new protocol version because every object is
closed to unknown properties. Existing versions remain immutable.
