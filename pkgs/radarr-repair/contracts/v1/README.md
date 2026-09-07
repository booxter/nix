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

Radarr status and error messages are represented as bounded opaque strings. The
contract assigns them no semantic categories, so new or mixed messages require
no protocol change.

A case contains one or more safe media-file observations and may advertise no
capabilities. File disposition records whether a file was a probe candidate or
evidence only and why. Torrent index, wanted state, and completed bytes are null
for an untracked filesystem file. Probe evidence is explicitly successful,
failed, or not collected. Radarr movie identity may be null when association
failed, and manual-import entries may have no rejection messages.

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

Version 1 offers three actions:

- `no_repair` records a bounded reason, missing-evidence categories, evidence
  references, and explanation.
- `join_parts_v1` selects one controller-advertised capability and orders two
  or more identifiers from its `candidate_file_ids` pool. The pool restricts
  which files the planner may reference; it does not assert that they belong
  together or carry aggregate join feasibility.
- `manual_import_file_v1` selects one controller-advertised capability and
  echoes its single file ID. The capability means the controller has already
  bound every Radarr import field needed for that file; those fields are not
  present in the decision.

The planner cannot select an output path or name, container, executable, or
command argument. A schema-valid join decision is still inert until the
controller validates identifier membership and calculates feasibility from the
selected ordered files before checking current source fingerprints and
execution policy.

When `capabilities` is empty, `no_repair` is the only semantically valid
decision. The controller will reject a schema-valid positive decision that does
not reference a capability offered by the case.

JSON Schema cannot compare the value of `file_id` in a decision with the value
bound to its referenced capability in an earlier request. The controller must
reject that mismatch during semantic validation. Closed decision objects still
let the schema reject attempts to supply a path, movie ID, quality, languages,
release group, import mode, or command parameters.

New optional evidence requires a new protocol version because every object is
closed to unknown properties. Existing versions remain immutable.
