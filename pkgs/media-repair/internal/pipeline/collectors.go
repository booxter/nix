package pipeline

import "context"

// AddFact puts a collector's result in the case after the read succeeds.
type AddFact[Facts any] func(*Facts)

// Each collector reads the same prepared input. A nil callback means the
// fact does not apply, for example when an optional reader is disabled.
type Collectors[Input, Facts any] []func(context.Context, Input) (AddFact[Facts], error)

// Collect runs readers in order under one deadline. The first error stops
// collection and the caller discards the unfinished case.
func (collectors Collectors[Input, Facts]) Collect(ctx context.Context, input Input, facts *Facts) error {
	for _, collect := range collectors {
		add, err := collect(ctx, input)
		if err != nil {
			return err
		}
		if add != nil {
			add(facts)
		}
	}
	return nil
}
