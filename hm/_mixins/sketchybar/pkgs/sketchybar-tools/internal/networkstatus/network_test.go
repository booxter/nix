package networkstatus

import (
	"net/netip"
	"testing"
)

func TestDetectSelectsConnectedAndVPNAddresses(t *testing.T) {
	cases := map[string]struct {
		interfaces []Interface
		want       Status
	}{
		"connected": {
			interfaces: []Interface{{
				Name: "en0", Up: true, Addresses: []netip.Addr{netip.MustParseAddr("192.168.1.20")},
			}},
			want: Status{Address: "192.168.1.20"},
		},
		"vpn": {
			interfaces: []Interface{
				{Name: "en0", Up: true, Addresses: []netip.Addr{netip.MustParseAddr("192.168.1.20")}},
				{Name: "utun4", Up: true, Addresses: []netip.Addr{netip.MustParseAddr("100.64.0.2")}},
			},
			want: Status{Address: "100.64.0.2", VPN: true},
		},
		"dormant tunnel": {
			interfaces: []Interface{{Name: "utun4", Up: true}},
			want:       Status{},
		},
		"disconnected": {},
	}
	for name, test := range cases {
		t.Run(name, func(t *testing.T) {
			if got := Detect(test.interfaces); got != test.want {
				t.Errorf("Detect = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestDetectPrefersIPv4AndIgnoresInactiveOrLocalAddresses(t *testing.T) {
	interfaces := []Interface{
		{Name: "en1", Up: false, Addresses: []netip.Addr{netip.MustParseAddr("10.0.0.2")}},
		{Name: "lo0", Up: true, Addresses: []netip.Addr{netip.MustParseAddr("127.0.0.1")}},
		{Name: "en0", Up: true, Addresses: []netip.Addr{
			netip.MustParseAddr("2001:db8::1"),
			netip.MustParseAddr("192.168.1.20"),
		}},
	}
	if got := Detect(interfaces); got.Address != "192.168.1.20" {
		t.Errorf("Detect address = %q, want 192.168.1.20", got.Address)
	}
}
