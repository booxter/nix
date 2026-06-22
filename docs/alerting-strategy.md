# Alerting Strategy

This document defines the repo's alerting architecture, ownership boundaries,
testing strategy, authoring rules, and implementation constraints.

The goal is to keep alerting predictable, testable, and reviewable as coverage
grows.

## Goals

- Alerting is defined as code in the repo.
- Alert evaluation does not depend on Grafana being healthy.
- Notification routing is centralized and consistent.
- Alerts are testable without causing real production failures.
- New alert families can be added without turning the repo into an alert DSL.
- Repeated boilerplate is reduced, but PromQL and routing logic remain explicit.
- The resulting system can scale from "a few alerts" to "many alerts" without
  forcing a redesign.

## Non-Goals

- This document does not define the final list of alerts we want.
- This document does not optimize for the smallest possible amount of code.
- This document does not try to invent a custom language for alerting.
- This document does not require HA now, but it should not block HA later.

## Summary Decision

Metric-based alerts should be evaluated by Prometheus, routed by Alertmanager,
and surfaced in Grafana.

That means:

- Prometheus owns alert rule evaluation.
- Alertmanager owns notification routing, grouping, silences, and inhibition.
- Grafana owns dashboards, Explore, alert visibility, and optional exception
  cases where an alert genuinely cannot live in Prometheus.

Grafana-managed alerts should be the exception, not the default.

## Architecture Rules

- Prometheus evaluates Prometheus metric alerts.
- Alertmanager is the single notification plane.
- Grafana is primarily UI.
- Grafana-managed alerts are exceptions for non-Prometheus or true
  multi-datasource cases.

This gives us:

- alert evaluation independent of Grafana
- native rule testing with `promtool`
- one routing and silence model
- fewer split-brain notification paths

## Service Architecture

### Core Components

- `fana` is the observability host and should own:
  - Prometheus
  - Alertmanager
  - Grafana
  - Loki
- monitored hosts should expose metrics only

### Responsibility Boundaries

- Prometheus: scrape, store, evaluate, send alerts
- Alertmanager: route, group, inhibit, silence, notify
- Grafana: dashboards, alert visibility, links, investigation

### HA Considerations

Single-instance observability is acceptable initially. The important
requirement is clean separation between evaluation, routing, and UI so HA can
be added later without redesigning the model.

## Source Of Truth

The source of truth for alerting should live in repo-managed files and modules,
not in Grafana's UI database.

### Canonical Data

The canonical artifacts should be:

- Prometheus alert rule files
- Prometheus recording rule files
- `promtool` test files
- Alertmanager config and templates
- Nix modules that wire those artifacts into services

### Repo Layout

The implementation lives under `nixos/fana/monitoring/`:

```text
docs/
  alerting-strategy.md

nixos/
  fana/
    default.nix
    monitoring/
      alertmanager/
        alertmanager.yml
        templates/
      prometheus/
        rules/
          availability.rules.yml
          backup.rules.yml
          control-plane.rules.yml
          custom-jobs.rules.yml
          dns.rules.yml
          fleet.rules.yml
          media-policy.rules.yml
          network-probes.rules.yml
          pki.rules.yml
          service-probes.rules.yml
          service-scrapes.rules.yml
          storage.rules.yml
          thermal.rules.yml
          ups.rules.yml
        tests/
          availability.rules.test.yml
          backup.rules.test.yml
          control-plane.rules.test.yml
          custom-jobs.rules.test.yml
          dns.rules.test.yml
          fleet.rules.test.yml
          media-policy.rules.test.yml
          network-probes.rules.test.yml
          pki.rules.test.yml
          service-probes.rules.test.yml
          service-scrapes.rules.test.yml
          storage.rules.test.yml
          thermal.rules.test.yml
          ups.rules.test.yml
      catalog.nix
```

Keep host wiring in `nixos/fana/default.nix`, but keep rule files, tests, and
Alertmanager config out of the main host file once the system grows.

### Implemented Baseline

The first deployable slice is already in place on `fana`:

- `nixos/fana/monitoring/default.nix` wires local Alertmanager and Prometheus
  rule files
- `nixos/fana/monitoring/catalog.nix` is the shared manifest used by modules
  and checks
- `nixos/fana/monitoring/alertmanager/alertmanager.yml` is the repo-managed
  Alertmanager config
- `nixos/fana/monitoring/prometheus/rules/{availability,backup,control-plane,custom-jobs,dns,fleet,media-policy,network-probes,pki,service-probes,service-scrapes,storage,thermal,ups}.rules.yml`
  hold the current repo-managed Prometheus alert families
- `nixos/fana/monitoring/prometheus/tests/*.rules.test.yml` hold the
  corresponding `promtool` rule tests

This is the baseline pattern to extend. New alert families should join this
structure rather than being added inline back into Grafana provisioning.

Grafana no longer owns these Prometheus-based POC alerts. It remains the UI,
and repo-managed Alertmanager is the notification plane.

### Formatting

If YAML is committed as source, formatting must be deterministic and enforced by
repo tooling. `nix fmt` and CI should cover alerting YAML the same way they
cover the rest of the repo so indentation and style do not depend on author
preference.

## NixOS Module Strategy

Use NixOS modules for wiring and light composition, not for inventing a custom
alert language.

Nix should handle:

- enabling Prometheus, Alertmanager, and Grafana
- wiring rule files, tests, templates, and secrets
- rendering native config files where useful
- exposing validation through flake checks

Nix should not initially:

- hide PromQL behind a custom abstraction
- replace Alertmanager routing syntax with a heavy object model
- auto-generate rule logic from prose
- auto-generate tests implicitly

Design rule: generate plumbing, not logic.

## Rule Definition Strategy

### Default Format

Prometheus alert rules should be authored in the Prometheus rule model:

- `groups`
- `rules`
- `alert`
- `expr`
- `for`
- `labels`
- `annotations`

This can be stored as:

- plain YAML checked into the repo
- or Nix attrsets rendered to YAML

Both are acceptable. The default preference should be:

- use a representation that stays very close to native Prometheus structure
- only add generation if it clearly reduces repetition

### Preferred Early Tradeoff

- keep rules close to native Prometheus structure
- keep tests in native `promtool` format
- use Nix to wire them into services
- only add helpers where repetition is obvious

### Recording Rules

Recording rules are precomputed Prometheus expressions stored as derived time
series. Use them when the same derived signal is needed in multiple alerts or
dashboards.

Introduce them when:

- the same PromQL expression is used in multiple alerts
- dashboards and alerts both need the same derived signal
- a complex expression is too expensive or noisy to repeat inline

## Alertmanager Strategy

Alertmanager should be introduced as a first-class service.

It should own:

- receivers
- route tree
- grouping and repeat behavior
- inhibition
- silences
- notification templates

Routes should key off stable labels, not only alert names. At minimum alerts
should carry:

- `severity`
- `category`
- `owner`
- `service`
- `scope`

The label model should support inhibition patterns such as:

- host-down inhibits service-down on that host
- exporter-down inhibits downstream metric alerts for that exporter
- site-wide outage inhibits individual service symptoms from that site

Assume at least these receiver classes:

- test receiver
- warning receiver
- critical receiver
- watchdog / heartbeat receiver

The transport can remain Telegram initially, but the routing model should not
assume that forever.

## Grafana Strategy

Grafana remains the UI layer:

- dashboards
- alert inspection
- links to dashboards and logs
- visibility into active alerts and silences

Grafana-managed alerts are acceptable only when all of these are true:

- the alert genuinely depends on non-Prometheus data sources
- recreating it in Prometheus would be awkward or misleading
- we still route notifications through the same operational path

## Testing Strategy

Testing must cover rendering, syntax, semantics, and deployment wiring.

### Layer 1: Nix Evaluation And Rendering

We should verify that the repo can render the alerting stack correctly.

At minimum:

- `nix build .#nixosConfigurations.<observability-host>.config.system.build.toplevel`

This catches:

- broken module wiring
- missing files
- invalid option structure
- secret path issues

This layer is necessary but not sufficient.

### Layer 2: Static Config Validation

Prometheus rules and Alertmanager config should be validated directly.

At minimum:

- `promtool check rules nixos/fana/monitoring/prometheus/rules/*.rules.yml`
- `amtool check-config nixos/fana/monitoring/alertmanager/alertmanager.yml`

If rule files are generated by Nix, CI should validate the rendered outputs,
not only the source templates.

### Layer 3: Unit Tests For Rule Semantics

Prometheus rules should have unit tests in `promtool` format.

These tests should use synthetic input series and verify:

- alert does not fire when healthy
- alert does not fire before the `for` duration elapses
- alert fires after the `for` duration elapses
- alert resolves when the signal recovers
- missing-data behavior is correct where relevant

This is the main way to test alerts without causing real violations.

### Layer 4: Route And Receiver Validation

Routing logic also needs validation:

- expected receiver for warning alerts
- expected receiver for critical alerts
- expected inhibition relationships
- test alerts do not route to production channels

Alertmanager config structure can be validated statically, but route behavior
also needs at least manual or scripted scenario checks.

### Layer 5: Runtime Smoke Tests

For changes that touch real deployment wiring:

- deploy with `nixos-rebuild test` where practical
- verify Prometheus loads the rules
- verify Alertmanager loads the config
- verify Grafana sees active alerts and Alertmanager status

These are operational smoke tests, not replacements for unit tests.

### Operational Rollout Loop

The normal rollout loop for this repo should be:

1. change rules, tests, or routing in Git
2. run local formatting and flake checks
3. commit the change
4. push the branch
5. deploy `fana` from that branch
6. verify Prometheus, Alertmanager, and Grafana runtime state

Current branch deployment command:

```sh
nix run .#deploy -- --branch <branch> fana
```

Current runtime verification should include:

- Prometheus rule load via `api/v1/rules`
- Alertmanager config/status via `api/v2/status`
- service health for `prometheus`, `alertmanager`, and `grafana`
- notification-path proof when routing changes materially

## CI And `flake check` Integration

Alerting validation must be part of the normal repo gate, not an optional local
script.

This repo already has the right structural hook for that:

- flake `checks` are defined centrally
- GitHub CI already runs the regular checks workflow
- NixOS integration tests already have a separate CI path

Alerting should plug into that existing structure.

### Required CI Expectations

- broken alert rules must fail CI
- broken Alertmanager config must fail CI
- broken alert unit tests must fail CI
- rendered config drift or invalid generation must fail CI
- changes must not be deployable if they do not pass these checks

### Expected Wiring

Static alert validations should become normal flake checks, for example by
extending `checks.nix` with derivations that run:

- `promtool check rules`
- `promtool test rules`
- `amtool check-config`
- any rendered-file validation needed for generated outputs

That keeps alert validation in the same path as the rest of the repo's regular
check suite instead of introducing a parallel workflow.

### Current Checks

Current alerting checks:

- `fana-alertmanager-config`
- `fana-prometheus-alerting`

They currently cover:

- `amtool check-config`
- `promtool check rules`
- `promtool test rules`

New rule files and test files should be wired through the shared monitoring
catalog so the service config and flake checks stay in sync.

Current scope:

- availability alert rules
- backup alert rules
- control-plane alert rules
- custom job alert rules
- DNS alert rules
- fleet alert rules
- media-policy alert rules
- network probe alert rules
- UPS alert rules
- PKI alert rules
- service probe alert rules
- service scrape alert rules
- storage alert rules
- thermal alert rules

### Integration Tests In CI

If we add runtime or service-level alerting tests later, they should fit into
the existing NixOS test path rather than bypassing it.

That means:

- fast static checks belong in flake `checks`
- heavier runtime tests belong in NixOS test jobs where justified
- the split should be based on cost, not on convenience

### Practical Rule

If an alerting change can break production evaluation or notification flow, it
must have a corresponding CI-enforced validation path.

There should be no class of alerting change that only "works if the author
remembered to run a local script".

## What Should Be Tested For Every Alert

Every alert should meet a minimum quality bar before it is considered done.

### Required Semantic Checks

- healthy case does not fire
- bad case eventually fires
- `for` window is long enough to avoid flapping but short enough to matter
- recovery clears the alert
- missing-data behavior is intentional

### Required Operational Metadata

- stable alert name
- `severity`
- `category`
- `owner`
- clear `summary`
- actionable `description`
- `runbook_url`
- dashboard link or dashboard identifier

### Required Design Checks

- the alert represents a meaningful symptom or clear control-plane failure
- the alert is actionable by a human
- cardinality is bounded
- labels are stable enough for routing and silencing
- inhibition relationships are identified if relevant
- the alert is not a duplicate of an existing broader alert

### Required Testing Artifacts

- `promtool` test coverage
- route expectation documented
- receiver expectation documented

## What Should Be Tested For Every Rule Group

Each rule group should also be reviewed as a unit.

- group interval is appropriate for the signal class
- alerts in the group are from the same domain or failure family
- group naming is stable and predictable
- labels are normalized across rules
- group does not mix unrelated concepts just for convenience
- heavy shared expressions are promoted to recording rules if needed

## What Should Be Tested For Every Receiver Or Route

- notification reaches the intended sink
- grouping is acceptable and not too noisy
- repeats are acceptable
- inhibition does not hide needed alerts
- silencing workflow is documented
- test alerts cannot page or spam production channels

## What Should Be Tested For Every Monitored Service Class

When onboarding a service or exporter, we should ask:

- do we have a scrape for it?
- do we have an availability alert for the scrape or exporter?
- do we have at least one quality or freshness alert for the signal?
- do we have a dashboard or graph link for investigation?
- do we know what "missing data" means for this source?
- do we know who owns the service?

This avoids a failure mode where dashboards exist but no one is alerted when
the telemetry disappears.

## Missing Data Strategy

Missing data must be intentional. We should not rely on tool defaults unless
the behavior is clearly desired.

For Prometheus-rule-based alerting:

- missing-data behavior should be expressed in PromQL where possible
- alerts that care about absence should use explicit absence or freshness logic
- alerts that only care about bad values should say so in tests

This is better than relying on platform-specific "NoData", "OK", or
"Alerting" defaults hidden inside a UI engine.

## Duplication Strategy

Reduce duplication without hiding logic.

Safe patterns:

- recording rules for reused expressions
- shared labels and annotations helpers
- shared runbook URL helpers
- standard route labels
- thin Nix helpers that assemble file lists or group defaults

Unsafe patterns:

- abstracting PromQL away entirely
- generating tests without explicit expected behavior
- inventing a custom alert object model that is harder to read than YAML

If a helper makes the rendered rule harder to understand than plain Prometheus
YAML, the helper is too smart.

## Current State

The implemented model on `fana` is:

- Prometheus evaluates the repo-managed metric alerts.
- Alertmanager is the single notification plane.
- Grafana is the UI for dashboards, inspection, and investigation.
- Alert rules, routing config, and tests live in Git and are wired by Nix.

Current coverage includes:

- availability and missing-telemetry alerts
- DNS, network probe, and service probe alerts
- direct scrape health for critical applications
- fleet health, backup health, and repo-specific policy jobs
- PKI inventory, expiry, and controller workflow alerts
- Beast storage, SMART, RAID, and HBA integrity alerts
- observability control-plane alerts for Prometheus, Alertmanager, and Grafana

Deliberate dashboard-only decisions:

- `node_btrfs_used_bytes` metadata/system chunk ratios stay dashboard-only.
  On the current Beast workload they sit close to fully allocated even in a
  healthy state, so they are not a clean free-space pressure alert signal.
- `host_observability_pki_cert_rotation_due` stays dashboard/controller-summary
  only. Being inside the rotation window is expected while the controller has
  already rotated certs and left an open review PR, so per-cert alerts would
  mostly page on normal workflow.

### Phase 4: Refine Shared Helpers

- only after several alert families exist
- extract repeated annotation and labeling patterns
- introduce recording rules for repeated expressions
- consider light rule-generation helpers if repetition clearly justifies them

### Phase 5: Add Pipeline Testing

- add a watchdog alert if it is still worth the complexity
- add a test receiver and synthetic alert path if needed
- validate end-to-end notification flow without touching production services

## Implementation Guardrails

These are the constraints that should guide future changes.

- Keep Prometheus rule logic close to native Prometheus format.
- Keep Alertmanager routing close to native Alertmanager format.
- Use Nix modules for wiring, validation, and small composition helpers.
- Prefer recording rules over inventing abstractions for repeated expressions.
- Prefer explicit unit tests over implicit or generated behavior.
- Treat Grafana as the UI, not the primary evaluation engine.
- Add Alertmanager before scaling the rule count materially.
- Never add a new alert family without deciding how it is tested.

## Success Criteria

We should consider the architecture successful when:

- alert rules, routing, and tests all live in Git
- Grafana is not required for alert evaluation
- there is a single notification plane
- every alert has explicit tests and required metadata
- we can validate changes locally and in CI without causing real incidents
- new alert families can be added by following a repeatable pattern instead of
  inventing a new structure each time
