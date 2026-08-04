package qos

import "net"

const (
	rootClassMinor      uint16 = 0x1
	wireGuardClassMinor uint16 = 0x10
	nfsClassMinor       uint16 = 0x15
	defaultClassMinor   uint16 = 0x20
)

type LeafQdisc string

const (
	NoLeafQdisc LeafQdisc = ""
	CakeQdisc   LeafQdisc = "cake"
	FqCodel     LeafQdisc = "fq_codel"
)

type IPFamily string

const (
	IPv4 IPFamily = "ipv4"
	IPv6 IPFamily = "ipv6"
)

type TransportProtocol string

const (
	UDP TransportProtocol = "udp"
	TCP TransportProtocol = "tcp"
)

type Class struct {
	Minor    uint16
	Parent   uint16
	RateBits uint64
	Leaf     LeafQdisc
}

type Filter struct {
	Family      IPFamily
	Protocol    TransportProtocol
	Priority    uint16
	SourcePort  uint16
	DestPort    uint16
	DestAddress net.IP
	ClassMinor  uint16
	RedirectIFB bool
}

type DownloadShape struct {
	RateBits uint64
	Filters  []Filter
}

type Topology struct {
	Classes  []Class
	Filters  []Filter
	Download *DownloadShape
}

func (config Config) Topology() Topology {
	topology := Topology{
		Classes: []Class{
			{Minor: rootClassMinor, RateBits: config.OuterRateBits},
			{
				Minor:    wireGuardClassMinor,
				Parent:   rootClassMinor,
				RateBits: config.WireGuard.UploadRateBits,
				Leaf:     CakeQdisc,
			},
			{
				Minor:    defaultClassMinor,
				Parent:   rootClassMinor,
				RateBits: config.OuterRateBits,
				Leaf:     FqCodel,
			},
		},
	}
	for priority, family := range []IPFamily{IPv4, IPv6} {
		filter := Filter{
			Family:     family,
			Protocol:   UDP,
			Priority:   uint16(10 + priority),
			ClassMinor: wireGuardClassMinor,
		}
		if config.WireGuard.EgressPort == SourcePort {
			filter.SourcePort = config.WireGuard.Port
		} else {
			filter.DestPort = config.WireGuard.Port
		}
		topology.Filters = append(topology.Filters, filter)
	}
	if config.NFS != nil {
		topology.Classes = append(topology.Classes, Class{
			Minor:    nfsClassMinor,
			Parent:   rootClassMinor,
			RateBits: config.NFS.RateBits,
			Leaf:     FqCodel,
		})
		topology.Filters = append(topology.Filters, Filter{
			Family:      IPv4,
			Protocol:    TCP,
			Priority:    15,
			DestPort:    config.NFS.Port,
			DestAddress: net.ParseIP(config.NFS.Address),
			ClassMinor:  nfsClassMinor,
		})
	}
	if config.WireGuard.DownloadRateBits != nil {
		download := &DownloadShape{RateBits: *config.WireGuard.DownloadRateBits}
		for priority, family := range []IPFamily{IPv4, IPv6} {
			download.Filters = append(download.Filters, Filter{
				Family:      family,
				Protocol:    UDP,
				Priority:    uint16(10 + priority),
				SourcePort:  config.WireGuard.Port,
				RedirectIFB: true,
			})
		}
		topology.Download = download
	}
	return topology
}
