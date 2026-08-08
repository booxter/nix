package qos

import (
	"strings"
	"testing"
)

func TestDecodeConfigRejectsUnknownAndInvalidFields(t *testing.T) {
	valid := `{
		"profile":"wan","interface":"ens18","nftTable":"qos_wan","linkRateBits":10000000000,
		"limits":[{"name":"wg","direction":"egress","rateBits":10000000,"queue":"cake",
		"classMinor":16,"ifbInterface":"","match":{"family":"both","protocol":"udp",
		"sourceAddress":null,"destinationAddress":null,"sourcePort":51820,"destinationPort":null,"users":[]}}]}`
	for name, document := range map[string]string{
		"unknown field":     strings.Replace(valid, `"profile":"wan"`, `"profile":"wan","typo":true`, 1),
		"empty interface":   strings.Replace(valid, `"interface":"ens18"`, `"interface":""`, 1),
		"zero rate":         strings.Replace(valid, `"rateBits":10000000`, `"rateBits":0`, 1),
		"user and port":     strings.Replace(valid, `"users":[]`, `"users":["backup"]`, 1),
		"invalid direction": strings.Replace(valid, `"direction":"egress"`, `"direction":"sideways"`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeConfig(strings.NewReader(document)); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

func TestWireGuardAndNFSTopology(t *testing.T) {
	config := Config{
		Profile:      "wan",
		Interface:    "ens18",
		NftTable:     "qos_wan",
		LinkRateBits: 10_000_000_000,
		Limits: []Limit{
			{
				Name:       "wireguard-upload",
				Direction:  Egress,
				RateBits:   8_000_000,
				Queue:      CakeQdisc,
				ClassMinor: 0x10,
				Match: Match{
					Family:          BothFamilies,
					Protocol:        UDP,
					DestinationPort: 1637,
				},
			},
			{
				Name:       "nfs",
				Direction:  Egress,
				RateBits:   1_500_000_000,
				Queue:      FqCodelQdisc,
				ClassMinor: 0x11,
				Match: Match{
					Family:             BothFamilies,
					Protocol:           TCP,
					DestinationAddress: "192.0.2.10",
					DestinationPort:    2049,
				},
			},
			{
				Name:         "wireguard-download",
				Direction:    Ingress,
				RateBits:     400_000_000,
				Queue:        CakeQdisc,
				IFBInterface: "ifb-q0-0",
				Match: Match{
					Family:     BothFamilies,
					Protocol:   UDP,
					SourcePort: 1637,
				},
			},
		},
	}
	if err := config.Validate(); err != nil {
		t.Fatal(err)
	}
	topology := config.Topology()
	assertClass(t, topology, "wireguard-upload", 0x10, 8_000_000, CakeQdisc)
	assertClass(t, topology, "nfs", 0x11, 1_500_000_000, FqCodelQdisc)
	assertPacketFilter(t, topology.EgressFilters, IPv4, UDP, 0, 1637, "", 0x10, "")
	assertPacketFilter(t, topology.EgressFilters, IPv6, UDP, 0, 1637, "", 0x10, "")
	assertPacketFilter(t, topology.EgressFilters, IPv4, TCP, 0, 2049, "192.0.2.10", 0x11, "")
	assertPacketFilter(t, topology.IngressFilters, IPv4, UDP, 1637, 0, "", 0, "ifb-q0-0")
	assertPacketFilter(t, topology.IngressFilters, IPv6, UDP, 1637, 0, "", 0, "ifb-q0-0")
	if len(topology.Ingress) != 1 || topology.Ingress[0].RateBits != 400_000_000 {
		t.Fatalf("unexpected ingress topology: %#v", topology.Ingress)
	}
}

func TestUserMatchTopology(t *testing.T) {
	config := Config{
		Profile:      "wan",
		Interface:    "enp6s0",
		NftTable:     "qos_wan",
		LinkRateBits: 10_000_000_000,
		Limits: []Limit{{
			Name:       "cloud-backup",
			Direction:  Egress,
			RateBits:   10_000_000,
			Queue:      FqCodelQdisc,
			ClassMinor: 0x10,
			Match: Match{
				Family: BothFamilies,
				Users:  []string{"restic-cloud", "restic-org-offload"},
			},
		}},
	}
	if err := config.Validate(); err != nil {
		t.Fatal(err)
	}
	topology := config.Topology()
	if len(topology.UserMarks) != 1 || topology.UserMarks[0].Mark != 0x10 {
		t.Fatalf("unexpected user marks: %#v", topology.UserMarks)
	}
	if len(topology.EgressFilters) != 2 {
		t.Fatalf("unexpected user filters: %#v", topology.EgressFilters)
	}
	for _, filter := range topology.EgressFilters {
		if filter.Mark != 0x10 || filter.ClassMinor != 0x10 {
			t.Fatalf("unexpected user filter: %#v", filter)
		}
	}
}

func assertClass(t *testing.T, topology Topology, name string, minor uint16, rate uint64, leaf LeafQdisc) {
	t.Helper()
	for _, class := range topology.Classes {
		if class.Name == name {
			if class.Minor != minor || class.RateBits != rate || class.Leaf != leaf {
				t.Fatalf("unexpected class %s: %#v", name, class)
			}
			return
		}
	}
	t.Fatalf("class %s not found", name)
}

func assertPacketFilter(
	t *testing.T,
	filters []Filter,
	family IPFamily,
	protocol TransportProtocol,
	sourcePort uint16,
	destinationPort uint16,
	destinationAddress string,
	classMinor uint16,
	redirectIFB string,
) {
	t.Helper()
	for _, filter := range filters {
		actualDestination := ""
		if filter.DestIP != nil {
			actualDestination = filter.DestIP.String()
		}
		if filter.Family == family && filter.Protocol == protocol &&
			filter.SourcePort == sourcePort && filter.DestPort == destinationPort &&
			actualDestination == destinationAddress && filter.ClassMinor == classMinor &&
			filter.RedirectIFB == redirectIFB {
			return
		}
	}
	t.Fatalf("packet filter not found: family=%s protocol=%s source=%d destination=%s:%d class=%x redirect=%s",
		family, protocol, sourcePort, destinationAddress, destinationPort, classMinor, redirectIFB)
}
