package podman

import "testing"

func TestDecodeMachineJSON(t *testing.T) {
	machines, err := decodeList([]byte(`[{"Name":"managed","VMType":"libkrun"}]`))
	if err != nil {
		t.Fatal(err)
	}
	if len(machines) != 1 || machines[0].Name != "managed" || machines[0].Provider != "libkrun" {
		t.Fatalf("unexpected machine list: %#v", machines)
	}

	state, err := decodeInspect([]byte(`[{"Resources":{"CPUs":4,"Memory":8192,"DiskSize":100},"State":"running"}]`))
	if err != nil {
		t.Fatal(err)
	}
	if state.CPUs != 4 || state.MemoryMiB != 8192 || state.DiskGiB != 100 || state.Status != "running" {
		t.Fatalf("unexpected machine state: %#v", state)
	}
}

func TestDecodeInspectRequiresOneMachine(t *testing.T) {
	if _, err := decodeInspect([]byte(`[]`)); err == nil {
		t.Fatal("empty inspect response unexpectedly accepted")
	}
}
