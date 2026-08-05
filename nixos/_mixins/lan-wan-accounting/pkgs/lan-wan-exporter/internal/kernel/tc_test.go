package kernel

import (
	"testing"

	tc "github.com/florianl/go-tc"
)

func TestClassBytesUsesMatchingHandleStatistics(t *testing.T) {
	handle, err := parseClassID("1:10")
	if err != nil {
		t.Fatal(err)
	}
	classes := []tc.Object{
		{Msg: tc.Msg{Handle: 0x10001}, Attribute: tc.Attribute{Stats2: &tc.Stats2{Bytes: 12}}},
		{Msg: tc.Msg{Handle: handle}, Attribute: tc.Attribute{Stats2: &tc.Stats2{Bytes: 345}}},
	}
	if got := classBytes(classes, handle); got != 345 {
		t.Fatalf("unexpected class bytes: %d", got)
	}
}

func TestParseClassIDRejectsInvalidValues(t *testing.T) {
	for _, value := range []string{"", "1", "1:", "xyz:10", "10000:1"} {
		if _, err := parseClassID(value); err == nil {
			t.Errorf("invalid class ID %q unexpectedly accepted", value)
		}
	}
}
