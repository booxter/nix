# Alerting Strategy

This repo's current alerting is a proof of concept: Grafana-managed rules on
`fanavm`, one notification path, and limited coverage. It is useful enough to
show alerts in chat, but it is not yet a good long-term architecture.

This document defines the target architecture, ownership boundaries, testing
strategy, authoring rules, and implementation constraints for a system that we
can extend incrementally without rewriting it every time a new alert class is
added.

The goal is not to finalize every threshold or receiver today. The goal is to
settle how alerting should be built so that adding or changing alerts later is
predictable, testable, and reviewable.

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
- This document does not assume we need HA immediately, though it should not
  block HA later.

## Summary Decision

Metric-based alerts should be evaluated by Prometheus, routed by Alertmanager,
and surfaced in Grafana.

That means:

- Prometheus owns alert rule evaluation.
- Alertmanager owns notification routing, grouping, silences, and inhibition.
- Grafana owns dashboards, Explore, alert visibility, and optional exception
  cases where an alert genuinely cannot live in Prometheus.

Grafana-managed alerts should be the exception, not the default.

## Why This Architecture

### Prometheus Should Evaluate Prometheus Metric Alerts

For the signals in this repo, Prometheus is already the source of truth:

- node exporter
- blackbox exporter
- smartctl exporter
- custom textfile metrics
- NUT exporter
- service exporters

Using Prometheus for these alerts has practical advantages:

- alert evaluation survives a Grafana outage
- the rule format is close to native PromQL instead of a UI-oriented model
- rules can be tested with `promtool`
- missing-data semantics can be expressed explicitly in PromQL instead of being
  hidden in Grafana alert state settings

### Alertmanager Should Be The Single Notification Brain

Notification logic gets messy quickly if multiple systems send alerts directly.

Alertmanager should be the only place that decides:

- who gets notified
- how alerts are grouped
- how often reminders repeat
- what gets inhibited by broader failures
- what can be silenced temporarily

This prevents a split-brain setup where:

- some alerts come from Grafana contact points
- others come from Prometheus + Alertmanager
- routing behavior differs by source

That becomes hard to reason about and hard to test.

### Grafana Should Mostly Be UI

Grafana is the right place for:

- dashboards
- visual exploration
- alert visibility
- links from alerts to graphs
- silence management when integrated with Alertmanager

Grafana-managed alerts still have a place, but only for cases such as:

- non-Prometheus data sources
- true multi-datasource correlation that Prometheus cannot express cleanly
- temporary experimental alerts before they are formalized

Even in those cases, they should route into the same Alertmanager if possible.

## Service Architecture

### Core Components

The long-term target architecture should have these roles:

- `fanavm` (or another observability host)
  - Prometheus
  - Alertmanager
  - Grafana
  - Loki
- monitored hosts
  - exporters and textfile metrics
  - no alert evaluation logic
  - no notification logic

### Responsibility Boundaries

Prometheus:

- scrapes metrics
- stores time series
- evaluates alert rules
- sends firing alerts to Alertmanager

Alertmanager:

- groups similar alerts
- handles deduplication and repeat intervals
- applies routing policies
- applies inhibition policies
- applies silences
- sends notifications to chat, webhooks, or paging systems

Grafana:

- shows dashboards and active alerts
- links alerts to graphs and logs
- may expose silence workflows
- should not be the default alert evaluator for Prometheus metrics

### HA Considerations

We do not need full HA immediately, but we should avoid choices that block it.

If we later want HA:

- Prometheus can remain single-instance initially
- Alertmanager can be run as a small cluster when needed
- Grafana can stay logically separate from alert evaluation

The important point now is architectural separation, not immediate duplication
of every service.

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

### Suggested Layout

This is a reasonable target layout:

```text
docs/
  alerting-strategy.md

monitoring/
  alertmanager/
    alertmanager.yml
    templates/
      default.tmpl
  prometheus/
    rules/
      base.rules.yml
      dns.rules.yml
      storage.rules.yml
      pki.rules.yml
      ups.rules.yml
    tests/
      dns.test.yml
      storage.test.yml
      pki.test.yml
      ups.test.yml

nixos/
  _mixins/
    alerting/
      default.nix
      prometheus-rules.nix
      alertmanager.nix
```

This layout keeps:

- native rule logic near native formats
- tests near rules
- service wiring in Nix
- docs separate from implementation

### Why Not Keep Rules Inline In Host Config

Small inline rule sets are manageable.

Large inline rule sets become difficult because:

- rule logic is mixed with unrelated service config
- code review becomes noisy
- testing and generation paths are harder to isolate
- alert inventory is harder to scan

The current `fanavm/default.nix` proof of concept is acceptable as a starting
point, but it should not remain the long-term home for a growing rule set.

## NixOS Module Strategy

We should use NixOS modules for service wiring and light composition, but avoid
building a bespoke alert DSL too early.

### What Nix Should Do

Nix should be responsible for:

- enabling Prometheus, Alertmanager, and Grafana
- pointing Prometheus at rule files
- pointing Alertmanager at config/templates
- provisioning Grafana with Prometheus, Loki, and Alertmanager integration
- running validation hooks where possible
- aggregating small pieces of shared metadata or repeated defaults

### What Nix Should Not Do Initially

Nix should not initially:

- replace PromQL with a homegrown abstraction
- replace Alertmanager routing syntax with a complicated object model
- auto-generate rule logic from high-level prose
- auto-generate full rule tests from alert definitions

Those approaches look convenient early and become opaque later.

### Design Principle

Generate plumbing, not logic.

Good use of generation:

- shared labels
- common annotations
- standard route fragments
- deterministic file rendering
- wiring service paths and secrets

Bad use of generation:

- hiding PromQL behind custom abstractions
- inventing a "smart" alert schema that is harder to review than YAML
- making tests implicit

### Thin Module Layer

A reasonable first module layer is a thin wrapper around native concepts.

For example:

- a Nix option for `ruleFiles`
- a Nix option for `alertmanagerConfig`
- a Nix option for `alertmanagerTemplates`
- a small helper library for repeated labels and annotations

That is enough to get modularity and validation without committing to a DSL.

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

Reasonable early tradeoff:

- keep rules close to native Prometheus structure
- keep tests in native `promtool` format
- use Nix to wire them into services
- optionally use small Nix helpers for repeated metadata

This gives us:

- easy review
- easy portability
- direct compatibility with `promtool`
- low cognitive overhead

### Recording Rules

Recording rules should be introduced whenever:

- the same PromQL expression is used in multiple alerts
- dashboards and alerts both need the same derived signal
- a complex expression is too expensive or noisy to repeat inline

Recording rules help reduce duplication more safely than inventing a higher
level DSL, because they remain a native Prometheus mechanism.

## Alertmanager Strategy

Alertmanager should be introduced as a first-class service, not as an optional
future cleanup item.

### Alertmanager Owns

- default receiver
- route tree
- grouping behavior
- repeat intervals
- inhibition rules
- silence behavior
- notification templates

### Routing Principles

Routing should be based on stable labels, not alert names alone.

At minimum, alerts should carry labels such as:

- `severity`
- `category`
- `owner`
- `service`
- `scope`

This allows routing by policy instead of by one-off special cases.

### Inhibition Principles

Alertmanager should suppress lower-value alerts during broader incidents.

Examples of the pattern we should support:

- host-down inhibits service-down on that host
- exporter-down inhibits downstream metric alerts for that exporter
- site-wide outage inhibits individual service symptoms from that site

We do not need to implement all of those on day one, but the label model
should allow them.

### Receivers

We should assume at least these logical receiver classes:

- test receiver
- warning receiver
- critical receiver
- watchdog / heartbeat receiver

The actual transport may remain Telegram initially, but the routing model
should not assume that forever.

### Watchdog

We should maintain a dedicated watchdog / deadman alert.

Its job is not to indicate a production failure directly. Its job is to prove
that the alert pipeline itself still works:

- rule evaluation
- alert delivery from Prometheus
- routing in Alertmanager
- final notification delivery

This should go to a dedicated low-noise receiver.

## Grafana Strategy

Grafana should remain in the system, but with clearer boundaries.

### Grafana Should Continue To Do

- dashboards
- alert inspection
- links to dashboards from alerts
- links to logs from alerts
- showing current active alert states

### Grafana Should Not Be The Canonical Store For Most Alerts

UI-managed state is a poor long-term source of truth because:

- it is harder to review
- it is harder to test in CI
- it is easier to drift from Git
- evaluation becomes coupled to Grafana

### Exception Cases

Grafana-managed alerts are acceptable when all of these are true:

- the alert genuinely depends on non-Prometheus data sources
- recreating it in Prometheus would be awkward or misleading
- we still route notifications through the same operational path

These should be rare and documented explicitly as exceptions.

## Testing Strategy

Testing needs to cover more than syntax. The useful model is layered.

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

- `promtool check rules monitoring/prometheus/rules/*.rules.yml`
- `amtool check-config monitoring/alertmanager/alertmanager.yml`

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

### Layer 5: End-To-End Pipeline Tests

We should test the live pipeline without causing real service failures.

Preferred mechanisms:

- watchdog alert that is always or regularly firing
- a dedicated synthetic test alert
- manual injection of a synthetic alert into Alertmanager with clearly scoped
  labels like `alert_test="true"`

The test path must route to a test receiver, not the main production receiver.

### Layer 6: Runtime Smoke Tests

For changes that touch real deployment wiring:

- deploy with `nixos-rebuild test` where practical
- verify Prometheus loads the rules
- verify Alertmanager loads the config
- verify Grafana sees active alerts and Alertmanager status

These are operational smoke tests, not replacements for unit tests.

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

We want to reduce duplication, but not at the cost of clarity.

### Safe Ways To Reduce Duplication

- recording rules for reused expressions
- shared labels and annotations helpers
- shared runbook URL helpers
- standard route labels
- thin Nix helpers that assemble file lists or group defaults

### Unsafe Ways To Reduce Duplication

- abstracting PromQL away entirely
- generating tests without explicit expected behavior
- inventing a custom alert object model that is harder to read than YAML

### Practical Rule

If a helper makes the rendered rule harder to understand than plain Prometheus
YAML, the helper is too smart.

### Recommended Balance

Start with native formats and shallow helpers.

Only add meta-generation after repetition is real and obvious.

That means:

- do not rush into a custom DSL
- do allow a small library of helper constructors
- do prefer explicit PromQL
- do prefer explicit `promtool` tests

## Recommended Implementation Phases

This is not the execution plan yet, but it is the intended order of maturity.

### Phase 1: Establish The Backbone

- add Alertmanager
- move alert definitions out of Grafana-managed-only ownership
- define file layout for rules, tests, and routing
- wire services with Nix modules

### Phase 2: Migrate Existing Alerts

- port the current Grafana proof-of-concept alerts to Prometheus rules
- keep semantics close to current behavior
- add `promtool` tests for each migrated rule group

### Phase 3: Add Pipeline Testing

- add a watchdog alert
- add a test receiver and explicit synthetic alert path
- validate end-to-end notification flow

### Phase 4: Expand Coverage

- add availability alerts for critical scrapes
- add absence/freshness alerts where dashboards currently depend on missing
  telemetry
- add storage, service, and fleet health alerts incrementally

### Phase 5: Refine Shared Helpers

- only after several alert families exist
- extract repeated annotation and labeling patterns
- introduce recording rules for repeated expressions
- consider light rule-generation helpers if repetition clearly justifies them

## Implementation Guardrails

These are the constraints that should guide autonomous execution later.

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
- we can trigger a synthetic alert end to end without touching production
  services
- new alert families can be added by following a repeatable pattern instead of
  inventing a new structure each time
