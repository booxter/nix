package networkstatus

import (
	"errors"
	"net/netip"
	"reflect"
	"testing"
)

type fakeProvider struct {
	interfaces []Interface
	err        error
}

func (provider fakeProvider) Interfaces() ([]Interface, error) {
	return provider.interfaces, provider.err
}

type recordingBar struct {
	calls [][]string
	err   error
}

func (bar *recordingBar) Run(arguments ...string) error {
	bar.calls = append(bar.calls, append([]string(nil), arguments...))
	return bar.err
}

func testConfig() Config {
	return Config{Name: "ip_address", SketchybarExecutable: "/sketchybar"}
}

func TestRunShowsCurrentAddress(t *testing.T) {
	provider := fakeProvider{interfaces: []Interface{{
		Name: "en0", Up: true, Addresses: []netip.Addr{netip.MustParseAddr("192.168.1.20")},
	}}}
	bar := &recordingBar{}
	if err := Run(testConfig(), provider, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{"--set", "ip_address", "icon=" + connectedIcon, "label=192.168.1.20"}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunShowsVPNAndTogglesLabelWhenClicked(t *testing.T) {
	config := testConfig()
	config.Sender = "mouse.clicked"
	provider := fakeProvider{interfaces: []Interface{{
		Name: "utun4", Up: true, Addresses: []netip.Addr{netip.MustParseAddr("100.64.0.2")},
	}}}
	bar := &recordingBar{}
	if err := Run(config, provider, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{
		"--set", "ip_address", "icon=" + vpnIcon, "label=100.64.0.2", "label.drawing=toggle",
	}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunShowsDisconnectedStateWhenInterfacesAreUnavailable(t *testing.T) {
	bar := &recordingBar{}
	if err := Run(testConfig(), fakeProvider{err: errors.New("unavailable")}, bar); err != nil {
		t.Fatalf("Run returned an error: %v", err)
	}
	want := [][]string{{
		"--set", "ip_address", "icon=" + disconnectedIcon, "label=Not Connected",
	}}
	if !reflect.DeepEqual(bar.calls, want) {
		t.Fatalf("SketchyBar calls = %#v, want %#v", bar.calls, want)
	}
}

func TestRunPropagatesSketchybarFailure(t *testing.T) {
	bar := &recordingBar{err: errors.New("bar failed")}
	if err := Run(testConfig(), fakeProvider{}, bar); err == nil {
		t.Fatal("expected SketchyBar failure")
	}
}

func TestConfigFromEnvironmentValidatesSettings(t *testing.T) {
	values := map[string]string{
		"NAME":           "ip_address",
		"SKETCHYBAR_BIN": "/sketchybar",
	}
	if _, err := ConfigFromEnvironment(func(name string) string { return values[name] }); err != nil {
		t.Fatalf("ConfigFromEnvironment returned an error: %v", err)
	}
	delete(values, "SKETCHYBAR_BIN")
	if _, err := ConfigFromEnvironment(func(name string) string { return values[name] }); err == nil {
		t.Fatal("missing SketchyBar executable should fail")
	}
}
