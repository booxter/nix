package planningstate

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

const testCaseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type testCase struct {
	CaseID   string `json:"case_id"`
	Evidence string `json:"evidence"`
	Local    string `json:"local"`
}

func TestCaseStoreRefreshesObservationWithoutReplacingIdentity(t *testing.T) {
	t.Parallel()
	store := newTestCaseStore(t)
	first := testCase{CaseID: testCaseID, Evidence: "same", Local: "first"}
	observed, err := store.Observe(first, nil)
	if err != nil || !observed.Created || !observed.Updated {
		t.Fatalf("first observation = %#v, error = %v", observed, err)
	}
	second := testCase{CaseID: testCaseID, Evidence: "same", Local: "second"}
	observed, err = store.Observe(second, nil)
	if err != nil || observed.Created || !observed.Updated {
		t.Fatalf("second observation = %#v, error = %v", observed, err)
	}
	stored, found, err := store.Get(testCaseID)
	if err != nil || !found || stored.Local != "second" || stored.Evidence != "same" {
		t.Fatalf("stored = %#v, found = %t, error = %v", stored, found, err)
	}
}

func TestCaseStoreRejectsIdentityCollision(t *testing.T) {
	t.Parallel()
	store := newTestCaseStore(t)
	if _, err := store.Observe(
		testCase{CaseID: testCaseID, Evidence: "first", Local: "one"}, nil,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Observe(
		testCase{CaseID: testCaseID, Evidence: "second", Local: "two"}, nil,
	); err == nil {
		t.Fatal("identity collision was accepted")
	}
}

func newTestCaseStore(t *testing.T) *CaseStore[testCase] {
	t.Helper()
	store, err := NewCaseStore(
		filepath.Join(t.TempDir(), "cases"),
		func() (func(), error) { return func() {}, nil },
		CaseCodec[testCase]{
			CaseID: func(record testCase) string { return record.CaseID },
			Encode: func(record testCase) ([]byte, error) { return json.Marshal(record) },
			Decode: func(data []byte) (testCase, error) {
				var record testCase
				err := json.Unmarshal(data, &record)
				return record, err
			},
			SameIdentity: func(left, right testCase) (bool, error) {
				return left.Evidence == right.Evidence, nil
			},
			Merge: func(stored, current testCase) (testCase, error) {
				current.Evidence = stored.Evidence
				return current, nil
			},
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	return store
}
