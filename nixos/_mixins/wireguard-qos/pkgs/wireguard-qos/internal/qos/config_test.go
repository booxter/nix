package qos

import (
	"strings"
	"testing"
)

func TestDecodeConfigRejectsUnknownAndInvalidFields(t *testing.T) {
	for name, document := range map[string]string{
		"unknown field": `{
			"interface":"ens18","routeProbe":"1.1.1.1","outerRateBits":10000000,
			"wireguard":{"port":1637,"uploadRateBits":1000000,"egressPort":"source","ifbInterface":"ifb-wg"},
			"nfs":null,"typo":true}`,
		"missing route": `{
			"interface":"","routeProbe":"not-an-address","outerRateBits":10000000,
			"wireguard":{"port":1637,"uploadRateBits":1000000,"egressPort":"source","ifbInterface":"ifb-wg"},
			"nfs":null}`,
		"invalid direction": `{
			"interface":"ens18","routeProbe":"1.1.1.1","outerRateBits":10000000,
			"wireguard":{"port":1637,"uploadRateBits":1000000,"egressPort":"both","ifbInterface":"ifb-wg"},
			"nfs":null}`,
		"download without IFB": `{
			"interface":"ens18","routeProbe":"1.1.1.1","outerRateBits":10000000,
			"wireguard":{"port":1637,"uploadRateBits":1000000,"downloadRateBits":1000000,"egressPort":"source","ifbInterface":""},
			"nfs":null}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeConfig(strings.NewReader(document)); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

func TestGatewayTopology(t *testing.T) {
	config := Config{
		Interface:     "ens18",
		RouteProbe:    "1.1.1.1",
		OuterRateBits: 10_000_000_000,
		WireGuard: WireGuardConfig{
			Port:           51820,
			UploadRateBits: 10_000_000,
			EgressPort:     SourcePort,
		},
	}
	if err := config.Validate(); err != nil {
		t.Fatal(err)
	}
	topology := config.Topology()
	assertClass(t, topology, wireGuardClassMinor, 10_000_000, CakeQdisc)
	assertClass(t, topology, defaultClassMinor, 10_000_000_000, FqCodel)
	assertFilter(t, topology.Filters, IPv4, UDP, 10, 51820, 0, "", wireGuardClassMinor, false)
	assertFilter(t, topology.Filters, IPv6, UDP, 11, 51820, 0, "", wireGuardClassMinor, false)
	if topology.Download != nil {
		t.Fatal("gateway topology unexpectedly contains download shaping")
	}
}

func TestBidirectionalTopologyIncludesNFS(t *testing.T) {
	downloadRate := uint64(400_000_000)
	config := Config{
		RouteProbe:    "1.1.1.1",
		OuterRateBits: 10_000_000_000,
		WireGuard: WireGuardConfig{
			Port:             1637,
			UploadRateBits:   10_000_000,
			DownloadRateBits: &downloadRate,
			EgressPort:       DestinationPort,
			IFBInterface:     "ifb-wg",
		},
		NFS: &NFSConfig{Address: "192.0.2.10", Port: 2049, RateBits: 1_500_000_000},
	}
	if err := config.Validate(); err != nil {
		t.Fatal(err)
	}
	topology := config.Topology()
	assertClass(t, topology, nfsClassMinor, 1_500_000_000, FqCodel)
	assertFilter(t, topology.Filters, IPv4, UDP, 10, 0, 1637, "", wireGuardClassMinor, false)
	assertFilter(t, topology.Filters, IPv6, UDP, 11, 0, 1637, "", wireGuardClassMinor, false)
	assertFilter(t, topology.Filters, IPv4, TCP, 15, 0, 2049, "192.0.2.10", nfsClassMinor, false)
	if topology.Download == nil || topology.Download.RateBits != downloadRate {
		t.Fatalf("unexpected download topology: %#v", topology.Download)
	}
	assertFilter(t, topology.Download.Filters, IPv4, UDP, 10, 1637, 0, "", 0, true)
	assertFilter(t, topology.Download.Filters, IPv6, UDP, 11, 1637, 0, "", 0, true)
}

func assertClass(t *testing.T, topology Topology, minor uint16, rate uint64, leaf LeafQdisc) {
	t.Helper()
	for _, class := range topology.Classes {
		if class.Minor == minor {
			if class.RateBits != rate || class.Leaf != leaf {
				t.Fatalf("unexpected class 1:%x: %#v", minor, class)
			}
			return
		}
	}
	t.Fatalf("class 1:%x not found", minor)
}

func assertFilter(
	t *testing.T,
	filters []Filter,
	family IPFamily,
	protocol TransportProtocol,
	priority uint16,
	sourcePort uint16,
	destPort uint16,
	destAddress string,
	classMinor uint16,
	redirect bool,
) {
	t.Helper()
	for _, filter := range filters {
		actualDestAddress := ""
		if filter.DestAddress != nil {
			actualDestAddress = filter.DestAddress.String()
		}
		if filter.Family == family &&
			filter.Protocol == protocol &&
			filter.Priority == priority &&
			filter.SourcePort == sourcePort &&
			filter.DestPort == destPort &&
			actualDestAddress == destAddress &&
			filter.ClassMinor == classMinor &&
			filter.RedirectIFB == redirect {
			return
		}
	}
	t.Fatalf(
		"filter not found: family=%s protocol=%s priority=%d source=%d destination=%s:%d class=1:%x redirect=%t",
		family,
		protocol,
		priority,
		sourcePort,
		destAddress,
		destPort,
		classMinor,
		redirect,
	)
}
