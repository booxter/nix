package networkstatus

import (
	"fmt"
	"net"
	"net/netip"
	"strings"
)

type Interface struct {
	Name      string
	Up        bool
	Addresses []netip.Addr
}

type InterfaceProvider interface {
	Interfaces() ([]Interface, error)
}

type NativeInterfaceProvider struct{}

func (NativeInterfaceProvider) Interfaces() ([]Interface, error) {
	nativeInterfaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("list network interfaces: %w", err)
	}
	interfaces := make([]Interface, 0, len(nativeInterfaces))
	for _, nativeInterface := range nativeInterfaces {
		addresses, err := nativeInterface.Addrs()
		if err != nil {
			continue
		}
		item := Interface{
			Name: nativeInterface.Name,
			Up:   nativeInterface.Flags&net.FlagUp != 0,
		}
		for _, address := range addresses {
			rawAddress, _, _ := strings.Cut(address.String(), "/")
			rawAddress, _, _ = strings.Cut(rawAddress, "%")
			parsed, err := netip.ParseAddr(rawAddress)
			if err == nil {
				item.Addresses = append(item.Addresses, parsed.Unmap())
			}
		}
		interfaces = append(interfaces, item)
	}
	return interfaces, nil
}

type Status struct {
	Address string
	VPN     bool
}

func Detect(interfaces []Interface) Status {
	var regularAddress netip.Addr
	var vpnAddress netip.Addr
	vpn := false
	for _, networkInterface := range interfaces {
		if !networkInterface.Up {
			continue
		}
		isVPN := strings.HasPrefix(networkInterface.Name, "utun")
		for _, address := range networkInterface.Addresses {
			if !usable(address) {
				continue
			}
			if isVPN {
				vpn = true
				vpnAddress = preferIPv4(vpnAddress, address)
			} else {
				regularAddress = preferIPv4(regularAddress, address)
			}
		}
	}
	if vpn {
		return Status{Address: formatAddress(vpnAddress), VPN: true}
	}
	return Status{Address: formatAddress(regularAddress)}
}

func formatAddress(address netip.Addr) string {
	if !address.IsValid() {
		return ""
	}
	return address.String()
}

func usable(address netip.Addr) bool {
	return address.IsValid() &&
		!address.IsUnspecified() &&
		!address.IsLoopback() &&
		!address.IsLinkLocalUnicast()
}

func preferIPv4(current netip.Addr, candidate netip.Addr) netip.Addr {
	if !current.IsValid() || (!current.Is4() && candidate.Is4()) {
		return candidate
	}
	return current
}
