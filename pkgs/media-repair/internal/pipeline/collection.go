package pipeline

import (
	"context"
	"fmt"
	"slices"
)

// CollectionFlow defines how to turn a queue entry into a case for the planner.
// Validators share the result of one lookup per entry.
type CollectionFlow[Clients, Entry, Resolved, Case any] struct {
	Discover   func(Clients, context.Context) ([]Entry, error)
	Resolve    func(Clients, context.Context, Entry) (Resolved, error)
	Validators Validators[Resolved]
	Collect    func(Clients, context.Context, Resolved) (Case, error)
}

type Validators[Resolved any] []func(Resolved) []string

// findings collects all reasons to skip an entry. Two checks can flag the
// same problem, so each reason appears only once in the report.
func (validators Validators[Resolved]) findings(resolved Resolved) []string {
	var findings []string
	for _, validate := range validators {
		for _, finding := range validate(resolved) {
			if !slices.Contains(findings, finding) {
				findings = append(findings, finding)
			}
		}
	}
	return findings
}

// Result holds one of three things: the collected case, the reasons an entry
// was skipped, or the error that prevented inspection.
type Result[Case any] struct {
	Case     *Case
	Findings []string
	Err      error
}

// Run continues after an error on one entry. A queue read error, cancellation,
// or failure to report a result stops the whole scan.
func (flow CollectionFlow[Clients, Entry, Resolved, Case]) Run(
	ctx context.Context,
	clients Clients,
	report func(Entry, Result[Case]) error,
) error {
	entries, err := flow.Discover(clients, ctx)
	if err != nil {
		return fmt.Errorf("read queue: %w", err)
	}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		result := flow.inspect(ctx, clients, entry)
		// If shutdown interrupted this entry, stop before reporting it as a failure.
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := report(entry, result); err != nil {
			return err
		}
	}
	return nil
}

// inspect starts collection only when every check passes.
func (flow CollectionFlow[Clients, Entry, Resolved, Case]) inspect(
	ctx context.Context,
	clients Clients,
	entry Entry,
) Result[Case] {
	resolved, err := flow.Resolve(clients, ctx, entry)
	if err != nil {
		return Result[Case]{Err: fmt.Errorf("resolve queue entry: %w", err)}
	}

	if findings := flow.Validators.findings(resolved); len(findings) > 0 {
		return Result[Case]{Findings: findings}
	}

	collected, err := flow.Collect(clients, ctx, resolved)
	if err != nil {
		return Result[Case]{Err: fmt.Errorf("collect facts: %w", err)}
	}
	return Result[Case]{Case: &collected}
}
