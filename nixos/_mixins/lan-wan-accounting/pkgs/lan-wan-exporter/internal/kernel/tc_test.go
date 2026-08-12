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
	if got, found := classBytes(classes, handle); got != 123 || !found {
		t.Fatalf("expected Stats.Bytes 123, got %d", got)
	}
}

func TestClassBytesRejectsMissingStats(t *testing.T) {
	handle, err := parseClassID("1:10")
	if err != nil {
		t.Fatal(err)
	}
	classes := []tc.Object{
		{Msg: tc.Msg{Handle: handle}, Attribute: tc.Attribute{}},
	}
	if _, found := classBytes(classes, handle); found {
		t.Fatal("class without statistics unexpectedly accepted")
	}
}

func TestClassBytesRejectsMissingClass(t *testing.T) {
	handle, err := parseClassID("1:10")
	if err != nil {
		t.Fatal(err)
	}
	if _, found := classBytes(nil, handle); found {
		t.Fatal("missing class unexpectedly accepted")
	}
}

func TestParseClassIDRejectsInvalidValues(t *testing.T) {
	for _, value := range []string{"", "1", "1:", "xyz:10", "10000:1"} {
		if _, err := parseClassID(value); err == nil {
			t.Errorf("invalid class ID %q unexpectedly accepted", value)
		}
	}
}
