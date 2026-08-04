package kernel

import (
	"testing"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
)

func TestCounterValuesReadsNamedCounterObjects(t *testing.T) {
	objects := []nftables.Obj{
		&nftables.NamedObj{Name: "lan_in", Type: nftables.ObjTypeCounter, Obj: &expr.Counter{Bytes: 42}},
		&nftables.NamedObj{Name: "not_a_counter", Type: nftables.ObjTypeQuota},
	}
	values, err := counterValues(objects)
	if err != nil {
		t.Fatal(err)
	}
	if len(values) != 1 || values["lan_in"] != 42 {
		t.Fatalf("unexpected named counters: %#v", values)
	}
}
