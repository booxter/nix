package qos

import "net"

const (
	rootClassMinor    uint16 = 0x1
	defaultClassMinor uint16 = 0xfffe
)

type Class struct {
	Name     string
	Minor    uint16
	Parent   uint16
	RateBits uint64
	Leaf     LeafQdisc
}

type Filter struct {
	Family      IPFamily
	Protocol    TransportProtocol
	Priority    uint16
	SourceIP    net.IP
	DestIP      net.IP
	SourcePort  uint16
	DestPort    uint16
	ClassMinor  uint16
	Mark        uint32
	RedirectIFB string
}

type UserMark struct {
	Users []string
	Mark  uint32
}

type IngressShape struct {
	Name         string
	IFBInterface string
	RateBits     uint64
	Queue        LeafQdisc
}

type Topology struct {
	Classes        []Class
	EgressFilters  []Filter
	UserMarks      []UserMark
	Ingress        []IngressShape
	IngressFilters []Filter
}

func (config Config) Topology() Topology {
	topology := Topology{}
	filterPriority := uint16(10)
	hasEgress := false
	for _, limit := range config.Limits {
		switch limit.Direction {
		case Egress:
			hasEgress = true
			topology.Classes = append(topology.Classes, Class{
				Name:     limit.Name,
				Minor:    limit.ClassMinor,
				Parent:   rootClassMinor,
				RateBits: limit.RateBits,
				Leaf:     limit.Queue,
			})
			if len(limit.Match.Users) != 0 {
				mark := uint32(limit.ClassMinor)
				topology.UserMarks = append(topology.UserMarks, UserMark{
					Users: limit.Match.Users,
					Mark:  mark,
				})
				for _, family := range []IPFamily{IPv4, IPv6} {
					topology.EgressFilters = append(topology.EgressFilters, Filter{
						Family:     family,
						Priority:   filterPriority,
						ClassMinor: limit.ClassMinor,
						Mark:       mark,
					})
					filterPriority++
				}
				continue
			}
			for _, family := range limit.Match.families() {
				topology.EgressFilters = append(topology.EgressFilters, limit.Match.filter(
					family,
					filterPriority,
					limit.ClassMinor,
					"",
				))
				filterPriority++
			}
		case Ingress:
			topology.Ingress = append(topology.Ingress, IngressShape{
				Name:         limit.Name,
				IFBInterface: limit.IFBInterface,
				RateBits:     limit.RateBits,
				Queue:        limit.Queue,
			})
			for _, family := range limit.Match.families() {
				topology.IngressFilters = append(topology.IngressFilters, limit.Match.filter(
					family,
					filterPriority,
					0,
					limit.IFBInterface,
				))
				filterPriority++
			}
		}
	}
	if hasEgress {
		topology.Classes = append(
			[]Class{{Minor: rootClassMinor, RateBits: config.LinkRateBits}},
			topology.Classes...,
		)
		topology.Classes = append(topology.Classes, Class{
			Name:     "default",
			Minor:    defaultClassMinor,
			Parent:   rootClassMinor,
			RateBits: config.LinkRateBits,
			Leaf:     FqCodelQdisc,
		})
	}
	return topology
}

func (match Match) families() []IPFamily {
	for _, value := range []string{match.SourceAddress, match.DestinationAddress} {
		if value == "" {
			continue
		}
		if net.ParseIP(value).To4() != nil {
			return []IPFamily{IPv4}
		}
		return []IPFamily{IPv6}
	}
	switch match.Family {
	case IPv4:
		return []IPFamily{IPv4}
	case IPv6:
		return []IPFamily{IPv6}
	default:
		return []IPFamily{IPv4, IPv6}
	}
}

func (match Match) filter(
	family IPFamily,
	priority uint16,
	classMinor uint16,
	redirectIFB string,
) Filter {
	return Filter{
		Family:      family,
		Protocol:    match.Protocol,
		Priority:    priority,
		SourceIP:    net.ParseIP(match.SourceAddress),
		DestIP:      net.ParseIP(match.DestinationAddress),
		SourcePort:  match.SourcePort,
		DestPort:    match.DestinationPort,
		ClassMinor:  classMinor,
		RedirectIFB: redirectIFB,
	}
}
