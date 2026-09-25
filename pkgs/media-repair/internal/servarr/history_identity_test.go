package servarr

import "testing"

type testHistoryIdentity struct {
	parent int64
	owner  int64
}

func TestSelectHistoryIdentity(t *testing.T) {
	valid := func(identity testHistoryIdentity) bool {
		return identity.parent > 0 && identity.owner > 0
	}

	tests := []struct {
		name       string
		identities []testHistoryIdentity
		want       testHistoryIdentity
		found      bool
		wantError  bool
	}{
		{name: "no history"},
		{
			name: "consistent history",
			identities: []testHistoryIdentity{
				{parent: 42, owner: 7},
				{parent: 42, owner: 7},
			},
			want:  testHistoryIdentity{parent: 42, owner: 7},
			found: true,
		},
		{
			name: "conflicting history",
			identities: []testHistoryIdentity{
				{parent: 42, owner: 7},
				{parent: 43, owner: 7},
			},
			wantError: true,
		},
		{
			name:       "invalid history",
			identities: []testHistoryIdentity{{parent: 42}},
			wantError:  true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, found, err := SelectHistoryIdentity(test.identities, valid)
			if (err != nil) != test.wantError {
				t.Fatalf("SelectHistoryIdentity() error = %v", err)
			}
			if err == nil && (got != test.want || found != test.found) {
				t.Fatalf("SelectHistoryIdentity() = (%+v, %v), want (%+v, %v)", got, found, test.want, test.found)
			}
		})
	}
}

func TestSelectHistoryIdentityRequiresValidator(t *testing.T) {
	if _, _, err := SelectHistoryIdentity([]int64{42}, nil); err == nil {
		t.Fatal("SelectHistoryIdentity() accepted a nil validator")
	}
}
