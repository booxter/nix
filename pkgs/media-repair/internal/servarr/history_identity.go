package servarr

import "fmt"

// SelectHistoryIdentity returns the sole identity supported by matching history
// records. Callers remain responsible for selecting records that belong to the
// exact download and for validating service-specific identity fields.
func SelectHistoryIdentity[Identity comparable](
	identities []Identity,
	valid func(Identity) bool,
) (Identity, bool, error) {
	var zero Identity
	if valid == nil {
		return zero, false, fmt.Errorf("history identity validator is required")
	}
	if len(identities) == 0 {
		return zero, false, nil
	}

	selected := identities[0]
	if !valid(selected) {
		return zero, false, fmt.Errorf("history contains an invalid identity")
	}
	for _, identity := range identities[1:] {
		if !valid(identity) {
			return zero, false, fmt.Errorf("history contains an invalid identity")
		}
		if identity != selected {
			return zero, false, fmt.Errorf("history contains conflicting identities")
		}
	}
	return selected, true, nil
}
