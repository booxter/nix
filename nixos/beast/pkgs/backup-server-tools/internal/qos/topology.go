package qos

const (
	rootClassMinor       uint16 = 0x1
	cloudClassMinor      uint16 = 0x10
	defaultClassMinor    uint16 = 0x20
	ethernetProtocolIPv4 uint16 = 0x0800
	ethernetProtocolIPv6 uint16 = 0x86dd
)

type Class struct {
	Minor    uint16
	Parent   uint16
	RateBits uint64
}

type Filter struct {
	Protocol uint16
	Priority uint16
	Mark     uint32
	Class    uint16
}

type Topology struct {
	Classes []Class
	Filters []Filter
}

func (config Config) Topology() Topology {
	return Topology{
		Classes: []Class{
			{Minor: rootClassMinor, RateBits: config.OuterRateBits},
			{Minor: cloudClassMinor, Parent: rootClassMinor, RateBits: config.CloudRateBits},
			{Minor: defaultClassMinor, Parent: rootClassMinor, RateBits: config.OuterRateBits},
		},
		Filters: []Filter{
			{Protocol: ethernetProtocolIPv4, Priority: 10, Mark: config.Mark, Class: cloudClassMinor},
			{Protocol: ethernetProtocolIPv6, Priority: 11, Mark: config.Mark, Class: cloudClassMinor},
		},
	}
}
