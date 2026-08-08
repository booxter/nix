//go:build linux

package bridgeaccess

import (
	"net/netip"
	"slices"
	"testing"
)

type memoryStore struct {
	rules   []Rule
	insert  []Rule
	remove  map[uint64]struct{}
	flushes int
}

func (store *memoryStore) ListOwned() ([]Rule, error) {
	return slices.Clone(store.rules), nil
}

func (store *memoryStore) Insert(rule Rule) {
	store.insert = append(store.insert, rule)
}

func (store *memoryStore) Delete(rule Rule) {
	if store.remove == nil {
		store.remove = make(map[uint64]struct{})
	}
	store.remove[rule.Handle] = struct{}{}
}

func (store *memoryStore) Flush() error {
	store.flushes++
	kept := make([]Rule, 0, len(store.rules)+len(store.insert))
	for _, rule := range store.rules {
		if _, remove := store.remove[rule.Handle]; !remove {
			kept = append(kept, rule)
		}
	}
	nextHandle := uint64(100)
	for _, rule := range store.insert {
		rule.Handle = nextHandle
		nextHandle++
		kept = append(kept, rule)
	}
	store.rules = kept
	store.insert = nil
	store.remove = nil
	return nil
}

func config(ports ...uint16) Config {
	return Config{
		Namespace:     "wg",
		SourceAddress: netip.MustParseAddr("192.168.50.5"),
		TCPPorts:      ports,
	}
}

func keys(rules []Rule) []ruleKey {
	result := make([]ruleKey, 0, len(rules))
	for _, rule := range rules {
		result = append(result, rule.key())
	}
	slices.SortFunc(result, func(left, right ruleKey) int {
		if left.TCPPort < right.TCPPort {
			return -1
		}
		if left.TCPPort > right.TCPPort {
			return 1
		}
		return left.SourceAddress.Compare(right.SourceAddress)
	})
	return result
}

func TestApplyConvergesOwnedRulesAndIsIdempotent(t *testing.T) {
	desired := config(443, 8080)
	store := &memoryStore{rules: []Rule{
		{Handle: 1, SourceAddress: desired.SourceAddress, TCPPort: 443},
		{Handle: 2, SourceAddress: desired.SourceAddress, TCPPort: 443},
		{Handle: 3, SourceAddress: desired.SourceAddress, TCPPort: 9000},
		{Handle: 4, SourceAddress: netip.MustParseAddr("192.168.50.6"), TCPPort: 8080},
	}}

	if err := Apply(desired, store); err != nil {
		t.Fatal(err)
	}
	want := []ruleKey{
		{SourceAddress: desired.SourceAddress, TCPPort: 443},
		{SourceAddress: desired.SourceAddress, TCPPort: 8080},
	}
	if got := keys(store.rules); !slices.Equal(got, want) {
		t.Fatalf("rules after apply = %#v, want %#v", got, want)
	}
	if store.flushes != 1 {
		t.Fatalf("flushes after reconciliation = %d, want 1", store.flushes)
	}
	if err := Apply(desired, store); err != nil {
		t.Fatal(err)
	}
	if store.flushes != 1 {
		t.Errorf("idempotent apply flushed again: %d", store.flushes)
	}
}

func TestRemoveDeletesEveryOwnedRule(t *testing.T) {
	desired := config(443, 8080)
	store := &memoryStore{rules: []Rule{
		{Handle: 1, SourceAddress: desired.SourceAddress, TCPPort: 443},
		{Handle: 2, SourceAddress: desired.SourceAddress, TCPPort: 8080},
	}}
	if err := Remove(store); err != nil {
		t.Fatal(err)
	}
	if len(store.rules) != 0 || store.flushes != 1 {
		t.Fatalf("remove left rules=%#v flushes=%d", store.rules, store.flushes)
	}
	if err := Remove(store); err != nil {
		t.Fatal(err)
	}
	if store.flushes != 1 {
		t.Errorf("empty remove flushed again: %d", store.flushes)
	}
}

func TestOwnerMetadataRoundTrips(t *testing.T) {
	want := Rule{SourceAddress: netip.MustParseAddr("192.168.50.5"), TCPPort: 443}
	got, ok := decodeOwner(encodeOwner(want))
	if !ok || got.key() != want.key() {
		t.Fatalf("decoded owner = %#v, %v; want %#v", got, ok, want)
	}
	if _, ok := decodeOwner([]byte("unrelated")); ok {
		t.Fatal("unrelated rule metadata accepted")
	}
}
