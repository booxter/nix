//go:build linux

package qos

import (
	"errors"
	"fmt"
	"net"

	tc "github.com/florianl/go-tc"
	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netlink/nl"
	"golang.org/x/sys/unix"
)

type Kernel struct {
	netlink *netlink.Handle
	tc      *tc.Tc
}

func OpenKernel() (*Kernel, error) {
	netlinkHandle, err := netlink.NewHandle()
	if err != nil {
		return nil, fmt.Errorf("open route netlink connection: %w", err)
	}
	tcHandle, err := tc.Open(&tc.Config{})
	if err != nil {
		netlinkHandle.Close()
		return nil, fmt.Errorf("open traffic-control netlink connection: %w", err)
	}
	return &Kernel{netlink: netlinkHandle, tc: tcHandle}, nil
}

func (kernel *Kernel) Close() error {
	kernel.netlink.Close()
	if err := kernel.tc.Close(); err != nil {
		return fmt.Errorf("close traffic-control netlink connection: %w", err)
	}
	return nil
}

func (kernel *Kernel) ResolveInterface(config Config) (netlink.Link, error) {
	if config.Interface != "" {
		link, err := kernel.netlink.LinkByName(config.Interface)
		if err != nil {
			return nil, fmt.Errorf("find interface %s: %w", config.Interface, err)
		}
		return link, nil
	}
	routes, err := kernel.netlink.RouteGet(net.ParseIP(config.RouteProbe))
	if err != nil {
		return nil, fmt.Errorf("resolve route to %s: %w", config.RouteProbe, err)
	}
	if len(routes) == 0 || routes[0].LinkIndex == 0 {
		return nil, fmt.Errorf("route to %s has no output interface", config.RouteProbe)
	}
	link, err := kernel.netlink.LinkByIndex(routes[0].LinkIndex)
	if err != nil {
		return nil, fmt.Errorf("find route output interface %d: %w", routes[0].LinkIndex, err)
	}
	return link, nil
}

func (kernel *Kernel) Start(config Config) (retErr error) {
	link, err := kernel.ResolveInterface(config)
	if err != nil {
		return err
	}
	var ifb netlink.Link
	if config.WireGuard.DownloadRateBits != nil {
		ifb, err = kernel.ensureIFB(config.WireGuard.IFBInterface)
		if err != nil {
			return err
		}
	}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, kernel.stopLinks(link, ifb, ifb != nil))
		}
	}()

	if err := kernel.deleteRoot(link); err != nil {
		return err
	}
	if err := kernel.addEgress(link, config.Topology()); err != nil {
		return err
	}
	if ifb != nil {
		if err := kernel.addIngress(link, ifb, config.Topology().Download); err != nil {
			return err
		}
	}
	return nil
}

func (kernel *Kernel) Stop(config Config) error {
	link, err := kernel.ResolveInterface(config)
	if err != nil {
		return err
	}
	var ifb netlink.Link
	if config.WireGuard.DownloadRateBits != nil {
		ifb, err = kernel.netlink.LinkByName(config.WireGuard.IFBInterface)
		if err != nil && !isLinkNotFound(err) {
			return fmt.Errorf("find IFB interface %s: %w", config.WireGuard.IFBInterface, err)
		}
	}
	return kernel.stopLinks(link, ifb, config.WireGuard.DownloadRateBits != nil)
}

func (kernel *Kernel) stopLinks(link, ifb netlink.Link, manageIngress bool) error {
	var errs []error
	if manageIngress {
		if err := kernel.deleteIngress(link); err != nil {
			errs = append(errs, err)
		}
	}
	if err := kernel.deleteRoot(link); err != nil {
		errs = append(errs, err)
	}
	if ifb != nil {
		if err := kernel.deleteRoot(ifb); err != nil {
			errs = append(errs, err)
		}
		if err := kernel.netlink.LinkSetDown(ifb); err != nil && !isMissing(err) {
			errs = append(errs, fmt.Errorf("set IFB interface down: %w", err))
		}
		if err := kernel.netlink.LinkDel(ifb); err != nil && !isMissing(err) {
			errs = append(errs, fmt.Errorf("delete IFB interface: %w", err))
		}
	}
	return errors.Join(errs...)
}

func (kernel *Kernel) ensureIFB(name string) (netlink.Link, error) {
	link, err := kernel.netlink.LinkByName(name)
	if err != nil {
		if !isLinkNotFound(err) {
			return nil, fmt.Errorf("find IFB interface %s: %w", name, err)
		}
		if err := kernel.netlink.LinkAdd(&netlink.Ifb{LinkAttrs: netlink.LinkAttrs{Name: name}}); err != nil {
			return nil, fmt.Errorf("create IFB interface %s: %w", name, err)
		}
		link, err = kernel.netlink.LinkByName(name)
		if err != nil {
			return nil, fmt.Errorf("find created IFB interface %s: %w", name, err)
		}
	}
	if link.Type() != "ifb" {
		return nil, fmt.Errorf("interface %s exists with type %s, expected ifb", name, link.Type())
	}
	if err := kernel.netlink.LinkSetUp(link); err != nil {
		return nil, fmt.Errorf("set IFB interface %s up: %w", name, err)
	}
	return link, nil
}

func (kernel *Kernel) addEgress(link netlink.Link, topology Topology) error {
	index := link.Attrs().Index
	root := netlink.NewHtb(netlink.QdiscAttrs{
		LinkIndex: index,
		Handle:    netlink.MakeHandle(1, 0),
		Parent:    netlink.HANDLE_ROOT,
	})
	root.Defcls = uint32(defaultClassMinor)
	root.Rate2Quantum = 1000
	if err := kernel.netlink.QdiscAdd(root); err != nil {
		return fmt.Errorf("add HTB root on %s: %w", link.Attrs().Name, err)
	}
	for _, class := range topology.Classes {
		if err := kernel.addClass(link, class); err != nil {
			return err
		}
	}
	for _, filter := range topology.Filters {
		if err := kernel.addFilter(link, netlink.MakeHandle(1, 0), 0, filter); err != nil {
			return err
		}
	}
	return nil
}

func (kernel *Kernel) addClass(link netlink.Link, class Class) error {
	parent := netlink.MakeHandle(1, 0)
	if class.Parent != 0 {
		parent = netlink.MakeHandle(1, class.Parent)
	}
	rateBytes := class.RateBits / 8
	htbClass := netlink.NewHtbClass(
		netlink.ClassAttrs{
			LinkIndex: link.Attrs().Index,
			Handle:    netlink.MakeHandle(1, class.Minor),
			Parent:    parent,
		},
		netlink.HtbClassAttrs{Rate: rateBytes, Ceil: rateBytes},
	)
	if err := kernel.netlink.ClassAdd(htbClass); err != nil {
		return fmt.Errorf("add HTB class 1:%x on %s: %w", class.Minor, link.Attrs().Name, err)
	}
	switch class.Leaf {
	case NoLeafQdisc:
		return nil
	case CakeQdisc:
		return kernel.addCake(link, class.Minor, class.RateBits, false)
	case FqCodel:
		qdisc := netlink.NewFqCodel(netlink.QdiscAttrs{
			LinkIndex: link.Attrs().Index,
			Handle:    netlink.MakeHandle(class.Minor, 0),
			Parent:    netlink.MakeHandle(1, class.Minor),
		})
		if err := kernel.netlink.QdiscAdd(qdisc); err != nil {
			return fmt.Errorf("add fq_codel for class 1:%x on %s: %w", class.Minor, link.Attrs().Name, err)
		}
		return nil
	default:
		return fmt.Errorf("unsupported leaf qdisc %q", class.Leaf)
	}
}

func (kernel *Kernel) addCake(link netlink.Link, minor uint16, rateBits uint64, ingress bool) error {
	baseRate := rateBits / 8
	bestEffort := uint32(3)
	enabled := uint32(1)
	cake := &tc.Cake{
		BaseRate:     &baseRate,
		DiffServMode: &bestEffort,
		Wash:         &enabled,
	}
	parent := netlink.MakeHandle(1, minor)
	handle := netlink.MakeHandle(minor, 0)
	if ingress {
		cake.Ingress = &enabled
		parent = netlink.HANDLE_ROOT
		handle = 0
	}
	object := &tc.Object{
		Msg: tc.Msg{
			Family:  unix.AF_UNSPEC,
			Ifindex: uint32(link.Attrs().Index),
			Handle:  handle,
			Parent:  parent,
		},
		Attribute: tc.Attribute{Kind: "cake", Cake: cake},
	}
	if err := kernel.tc.Qdisc().Add(object); err != nil {
		return fmt.Errorf("add CAKE qdisc on %s: %w", link.Attrs().Name, err)
	}
	return nil
}

func (kernel *Kernel) addIngress(link, ifb netlink.Link, download *DownloadShape) error {
	if download == nil {
		return fmt.Errorf("download topology is missing")
	}
	if err := kernel.deleteRoot(ifb); err != nil {
		return err
	}
	if err := kernel.addCake(ifb, 0, download.RateBits, true); err != nil {
		return err
	}
	if err := kernel.deleteIngress(link); err != nil {
		return err
	}
	ingress := &netlink.Ingress{QdiscAttrs: netlink.QdiscAttrs{
		LinkIndex: link.Attrs().Index,
		Handle:    netlink.MakeHandle(0xffff, 0),
		Parent:    netlink.HANDLE_INGRESS,
	}}
	if err := kernel.netlink.QdiscAdd(ingress); err != nil {
		return fmt.Errorf("add ingress qdisc on %s: %w", link.Attrs().Name, err)
	}
	for _, filter := range download.Filters {
		if err := kernel.addFilter(link, netlink.MakeHandle(0xffff, 0), ifb.Attrs().Index, filter); err != nil {
			return err
		}
	}
	return nil
}

func (kernel *Kernel) addFilter(link netlink.Link, parent uint32, redirectIndex int, filter Filter) error {
	protocol, err := ethernetProtocol(filter.Family)
	if err != nil {
		return err
	}
	ipProtocol, err := transportProtocol(filter.Protocol)
	if err != nil {
		return err
	}
	flower := &netlink.Flower{
		FilterAttrs: netlink.FilterAttrs{
			LinkIndex: link.Attrs().Index,
			Parent:    parent,
			Priority:  filter.Priority,
			Protocol:  protocol,
		},
		ClassId:  netlink.MakeHandle(1, filter.ClassMinor),
		IPProto:  &ipProtocol,
		SrcPort:  filter.SourcePort,
		DestPort: filter.DestPort,
		DestIP:   filter.DestAddress,
	}
	if filter.RedirectIFB {
		flower.ClassId = 0
		flower.Actions = []netlink.Action{netlink.NewMirredAction(redirectIndex)}
	}
	if err := kernel.netlink.FilterAdd(flower); err != nil {
		return fmt.Errorf("add priority %d flower filter on %s: %w", filter.Priority, link.Attrs().Name, err)
	}
	return nil
}

func ethernetProtocol(family IPFamily) (uint16, error) {
	switch family {
	case IPv4:
		return unix.ETH_P_IP, nil
	case IPv6:
		return unix.ETH_P_IPV6, nil
	default:
		return 0, fmt.Errorf("unsupported IP family %q", family)
	}
}

func transportProtocol(protocol TransportProtocol) (nl.IPProto, error) {
	switch protocol {
	case UDP:
		return nl.IPPROTO_UDP, nil
	case TCP:
		return nl.IPPROTO_TCP, nil
	default:
		return 0, fmt.Errorf("unsupported transport protocol %q", protocol)
	}
}

func (kernel *Kernel) deleteRoot(link netlink.Link) error {
	qdisc := &netlink.GenericQdisc{QdiscAttrs: netlink.QdiscAttrs{
		LinkIndex: link.Attrs().Index,
		Parent:    netlink.HANDLE_ROOT,
	}}
	if err := kernel.netlink.QdiscDel(qdisc); err != nil && !isMissing(err) {
		return fmt.Errorf("delete root qdisc from %s: %w", link.Attrs().Name, err)
	}
	return nil
}

func (kernel *Kernel) deleteIngress(link netlink.Link) error {
	qdisc := &netlink.GenericQdisc{QdiscAttrs: netlink.QdiscAttrs{
		LinkIndex: link.Attrs().Index,
		Handle:    netlink.MakeHandle(0xffff, 0),
		Parent:    netlink.HANDLE_INGRESS,
	}}
	if err := kernel.netlink.QdiscDel(qdisc); err != nil && !isMissing(err) {
		return fmt.Errorf("delete ingress qdisc from %s: %w", link.Attrs().Name, err)
	}
	return nil
}

func isLinkNotFound(err error) bool {
	var notFound netlink.LinkNotFoundError
	return errors.As(err, &notFound)
}

func isMissing(err error) bool {
	return errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ENODEV) || errors.Is(err, unix.EINVAL)
}
