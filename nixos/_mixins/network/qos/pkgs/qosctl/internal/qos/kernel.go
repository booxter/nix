//go:build linux

package qos

import (
	"errors"
	"fmt"
	"os/user"
	"strconv"

	tc "github.com/florianl/go-tc"
	"github.com/google/nftables"
	"github.com/google/nftables/binaryutil"
	"github.com/google/nftables/expr"
	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netlink/nl"
	"golang.org/x/sys/unix"
)

const markChainName = "output"

type Kernel struct {
	netlink *netlink.Handle
	tc      *tc.Tc
}

type resolvedUserMark struct {
	UID  uint32
	Mark uint32
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

func (kernel *Kernel) Start(config Config) (retErr error) {
	link, err := kernel.netlink.LinkByName(config.Interface)
	if err != nil {
		return fmt.Errorf("find interface %s: %w", config.Interface, err)
	}
	topology := config.Topology()
	marks, err := resolveUserMarks(topology.UserMarks)
	if err != nil {
		return err
	}
	if err := deleteMarkTable(config.NftTable); err != nil {
		return err
	}
	if err := kernel.stopTopology(link, topology); err != nil {
		return err
	}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, deleteMarkTable(config.NftTable), kernel.stopTopology(link, topology))
		}
	}()
	if len(marks) != 0 {
		if err := addMarkTable(config.NftTable, marks); err != nil {
			return err
		}
	}
	if len(topology.Classes) != 0 {
		if err := kernel.addEgress(link, topology); err != nil {
			return err
		}
	}
	if len(topology.Ingress) != 0 {
		if err := kernel.addIngress(link, topology); err != nil {
			return err
		}
	}
	return nil
}

func (kernel *Kernel) Stop(config Config) error {
	link, err := kernel.netlink.LinkByName(config.Interface)
	if err != nil {
		return fmt.Errorf("find interface %s: %w", config.Interface, err)
	}
	return errors.Join(deleteMarkTable(config.NftTable), kernel.stopTopology(link, config.Topology()))
}

func (kernel *Kernel) SetRate(config Config, limitName string, rateBits uint64) error {
	if rateBits == 0 || rateBits > config.LinkRateBits {
		return fmt.Errorf("rate must be positive and cannot exceed linkRateBits")
	}
	limit, err := config.Limit(limitName)
	if err != nil {
		return err
	}
	if limit.Direction != Egress {
		return fmt.Errorf("runtime rate updates require an egress limit")
	}
	link, err := kernel.netlink.LinkByName(config.Interface)
	if err != nil {
		return fmt.Errorf("find interface %s: %w", config.Interface, err)
	}
	class := Class{
		Name:     limit.Name,
		Minor:    limit.ClassMinor,
		Parent:   rootClassMinor,
		RateBits: rateBits,
		Leaf:     limit.Queue,
	}
	if err := kernel.changeClass(link, class); err != nil {
		return err
	}
	if limit.Queue == CakeQdisc {
		if err := kernel.changeCake(link, limit.ClassMinor, rateBits); err != nil {
			return err
		}
	}
	return nil
}

func (kernel *Kernel) stopTopology(link netlink.Link, topology Topology) error {
	var errs []error
	if len(topology.Ingress) != 0 {
		if err := kernel.deleteIngress(link); err != nil {
			errs = append(errs, err)
		}
	}
	if len(topology.Classes) != 0 {
		if err := kernel.deleteRoot(link); err != nil {
			errs = append(errs, err)
		}
	}
	for _, shape := range topology.Ingress {
		if err := kernel.deleteIFB(shape.IFBInterface); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (kernel *Kernel) deleteIFB(name string) error {
	link, err := kernel.netlink.LinkByName(name)
	if err != nil {
		if isLinkNotFound(err) {
			return nil
		}
		return fmt.Errorf("find IFB interface %s: %w", name, err)
	}
	var errs []error
	if err := kernel.deleteRoot(link); err != nil {
		errs = append(errs, err)
	}
	if err := kernel.netlink.LinkSetDown(link); err != nil && !isMissing(err) {
		errs = append(errs, fmt.Errorf("set IFB interface %s down: %w", name, err))
	}
	if err := kernel.netlink.LinkDel(link); err != nil && !isMissing(err) {
		errs = append(errs, fmt.Errorf("delete IFB interface %s: %w", name, err))
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
	root := netlink.NewHtb(netlink.QdiscAttrs{
		LinkIndex: link.Attrs().Index,
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
	for _, filter := range topology.EgressFilters {
		if err := kernel.addFilter(link, netlink.MakeHandle(1, 0), nil, filter); err != nil {
			return err
		}
	}
	return nil
}

func (kernel *Kernel) addClass(link netlink.Link, class Class) error {
	if err := kernel.netlink.ClassAdd(htbClass(link, class)); err != nil {
		return fmt.Errorf("add HTB class 1:%x on %s: %w", class.Minor, link.Attrs().Name, err)
	}
	switch class.Leaf {
	case "":
		return nil
	case CakeQdisc:
		return kernel.addCake(link, class.Minor, class.RateBits, false)
	case FqCodelQdisc:
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

func (kernel *Kernel) changeClass(link netlink.Link, class Class) error {
	if err := kernel.netlink.ClassChange(htbClass(link, class)); err != nil {
		return fmt.Errorf("change HTB class 1:%x on %s: %w", class.Minor, link.Attrs().Name, err)
	}
	return nil
}

func htbClass(link netlink.Link, class Class) netlink.Class {
	parent := netlink.MakeHandle(1, 0)
	if class.Parent != 0 {
		parent = netlink.MakeHandle(1, class.Parent)
	}
	// netlink.NewHtbClass accepts bits per second and converts them to the
	// bytes-per-second value used by the kernel internally. This differs from
	// go-tc's raw CAKE attribute below.
	return netlink.NewHtbClass(
		netlink.ClassAttrs{
			LinkIndex: link.Attrs().Index,
			Handle:    netlink.MakeHandle(1, class.Minor),
			Parent:    parent,
		},
		netlink.HtbClassAttrs{Rate: class.RateBits, Ceil: class.RateBits},
	)
}

func (kernel *Kernel) addCake(link netlink.Link, minor uint16, rateBits uint64, ingress bool) error {
	object := cakeObject(link, minor, rateBits, ingress)
	if err := kernel.tc.Qdisc().Add(object); err != nil {
		return fmt.Errorf("add CAKE qdisc on %s: %w", link.Attrs().Name, err)
	}
	return nil
}

func (kernel *Kernel) changeCake(link netlink.Link, minor uint16, rateBits uint64) error {
	object := cakeObject(link, minor, rateBits, false)
	if err := kernel.tc.Qdisc().Change(object); err != nil {
		return fmt.Errorf("change CAKE qdisc on %s: %w", link.Attrs().Name, err)
	}
	return nil
}

func cakeObject(link netlink.Link, minor uint16, rateBits uint64, ingress bool) *tc.Object {
	// CAKE's TCA_CAKE_BASE_RATE64 attribute is bytes per second. Unlike the
	// netlink HTB constructor above, go-tc passes this value through unchanged.
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
	return &tc.Object{
		Msg: tc.Msg{
			Family:  unix.AF_UNSPEC,
			Ifindex: uint32(link.Attrs().Index),
			Handle:  handle,
			Parent:  parent,
		},
		Attribute: tc.Attribute{Kind: "cake", Cake: cake},
	}
}

func (kernel *Kernel) addIngress(link netlink.Link, topology Topology) error {
	ifbs := make(map[string]netlink.Link, len(topology.Ingress))
	for _, shape := range topology.Ingress {
		ifb, err := kernel.ensureIFB(shape.IFBInterface)
		if err != nil {
			return err
		}
		ifbs[shape.IFBInterface] = ifb
		if err := kernel.deleteRoot(ifb); err != nil {
			return err
		}
		if shape.Queue != CakeQdisc {
			return fmt.Errorf("unsupported ingress queue %q", shape.Queue)
		}
		if err := kernel.addCake(ifb, 0, shape.RateBits, true); err != nil {
			return err
		}
	}
	ingress := &netlink.Ingress{QdiscAttrs: netlink.QdiscAttrs{
		LinkIndex: link.Attrs().Index,
		Handle:    netlink.MakeHandle(0xffff, 0),
		Parent:    netlink.HANDLE_INGRESS,
	}}
	if err := kernel.netlink.QdiscAdd(ingress); err != nil {
		return fmt.Errorf("add ingress qdisc on %s: %w", link.Attrs().Name, err)
	}
	for _, filter := range topology.IngressFilters {
		ifb := ifbs[filter.RedirectIFB]
		if err := kernel.addFilter(link, netlink.MakeHandle(0xffff, 0), ifb, filter); err != nil {
			return err
		}
	}
	return nil
}

func (kernel *Kernel) addFilter(link netlink.Link, parent uint32, redirect netlink.Link, filter Filter) error {
	protocol, err := ethernetProtocol(filter.Family)
	if err != nil {
		return err
	}
	if filter.Mark != 0 {
		fw := &netlink.FwFilter{
			FilterAttrs: netlink.FilterAttrs{
				LinkIndex: link.Attrs().Index,
				Handle:    filter.Mark,
				Parent:    parent,
				Priority:  filter.Priority,
				Protocol:  protocol,
			},
			ClassId: netlink.MakeHandle(1, filter.ClassMinor),
		}
		if err := kernel.netlink.FilterAdd(fw); err != nil {
			return fmt.Errorf("add priority %d fw filter on %s: %w", filter.Priority, link.Attrs().Name, err)
		}
		return nil
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
			Protocol:  unix.ETH_P_ALL,
		},
		ClassId:  netlink.MakeHandle(1, filter.ClassMinor),
		EthType:  protocol,
		IPProto:  &ipProtocol,
		SrcIP:    filter.SourceIP,
		DestIP:   filter.DestIP,
		SrcPort:  filter.SourcePort,
		DestPort: filter.DestPort,
	}
	if redirect != nil {
		flower.ClassId = 0
		flower.Actions = []netlink.Action{netlink.NewMirredAction(redirect.Attrs().Index)}
	}
	if err := kernel.netlink.FilterAdd(flower); err != nil {
		return fmt.Errorf("add priority %d flower filter on %s: %w", filter.Priority, link.Attrs().Name, err)
	}
	return nil
}

func resolveUserMarks(marks []UserMark) ([]resolvedUserMark, error) {
	var resolved []resolvedUserMark
	for _, mark := range marks {
		for _, name := range mark.Users {
			account, err := user.Lookup(name)
			if err != nil {
				return nil, fmt.Errorf("look up user %s: %w", name, err)
			}
			uid, err := strconv.ParseUint(account.Uid, 10, 32)
			if err != nil {
				return nil, fmt.Errorf("parse UID for user %s: %w", name, err)
			}
			resolved = append(resolved, resolvedUserMark{UID: uint32(uid), Mark: mark.Mark})
		}
	}
	return resolved, nil
}

func deleteMarkTable(name string) error {
	connection := &nftables.Conn{}
	tables, err := connection.ListTables()
	if err != nil {
		return fmt.Errorf("list nftables tables: %w", err)
	}
	for _, table := range tables {
		if table.Family == nftables.TableFamilyINet && table.Name == name {
			connection.DelTable(table)
			if err := connection.Flush(); err != nil {
				return fmt.Errorf("delete nftables table %s: %w", name, err)
			}
			return nil
		}
	}
	return nil
}

func addMarkTable(name string, marks []resolvedUserMark) error {
	connection := &nftables.Conn{}
	table := connection.AddTable(&nftables.Table{Family: nftables.TableFamilyINet, Name: name})
	policy := nftables.ChainPolicyAccept
	chain := connection.AddChain(&nftables.Chain{
		Name:     markChainName,
		Table:    table,
		Type:     nftables.ChainTypeRoute,
		Hooknum:  nftables.ChainHookOutput,
		Priority: nftables.ChainPriorityMangle,
		Policy:   &policy,
	})
	for _, mark := range marks {
		connection.AddRule(&nftables.Rule{
			Table: table,
			Chain: chain,
			Exprs: markExpressions(mark.UID, mark.Mark),
		})
	}
	if err := connection.Flush(); err != nil {
		return fmt.Errorf("install nftables UID marks: %w", err)
	}
	return nil
}

func markExpressions(uid, mark uint32) []expr.Any {
	return []expr.Any{
		&expr.Meta{Key: expr.MetaKeySKUID, Register: 1},
		&expr.Cmp{
			Op:       expr.CmpOpEq,
			Register: 1,
			Data:     binaryutil.NativeEndian.PutUint32(uid),
		},
		&expr.Immediate{Register: 1, Data: binaryutil.NativeEndian.PutUint32(mark)},
		&expr.Meta{Key: expr.MetaKeyMARK, SourceRegister: true, Register: 1},
	}
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
