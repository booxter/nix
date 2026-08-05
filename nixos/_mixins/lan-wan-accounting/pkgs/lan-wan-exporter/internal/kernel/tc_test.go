package kernel

import (
	"testing"

	tc "github.com/florianl/go-tc"
)

func TestClassBytesReturnsStatsBytes(t *testing.T) {
	handle, err := parseClassID("1:10")
	if err != nil {
		t.Fatal(err)
	}
	classes := []tc.Object{
		{Msg: tc.Msg{Handle: handle}, Attribute: tc.Attribute{
			Stats: &tc.Stats{Bytes: 123},
		}},
	}
	if got := classBytes(classes, handle); got != 123 {
		t.Fatalf("expected Stats.Bytes 123, got %d", got)
	}
}

func TestClassBytesReturnsZeroWhenNoStats(t *testing.T) {
	handle, err := parseClassID("1:10")
	if err != nil {
		t.Fatal(err)
	}
	classes := []tc.Object{
		{Msg: tc.Msg{Handle: handle}, Attribute: tc.Attribute{}},
	}
	if got := classBytes(classes, handle); got != 0 {
		t.Fatalf("expected 0 for missing stats, got %d", got)
	}
}

func TestParseClassIDRejectsInvalidValues(t *testing.T) {
	for _, value := range []string{"", "1", "1:", "xyz:10", "10000:1"} {
		if _, err := parseClassID(value); err == nil {
			t.Errorf("invalid class ID %q unexpectedly accepted", value)
		}
	}
}
