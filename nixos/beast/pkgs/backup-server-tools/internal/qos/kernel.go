//go:build linux

package qos

import (
	"errors"
	"fmt"
	"net"
	"os/user"
	"strconv"

	"github.com/google/nftables"
	"github.com/google/nftables/binaryutil"
	"github.com/google/nftables/expr"
	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

const (
	tableName = "backup_cloud_shaping"
	chainName = "output"
)

type Kernel struct {
	netlink *netlink.Handle
}

func OpenKernel() (*Kernel, error) {
	handle, err := netlink.NewHandle()
	if err != nil {
		return nil, fmt.Errorf("open route netlink connection: %w", err)
	}
	return &Kernel{netlink: handle}, nil
}

func (kernel *Kernel) Close() error {
	kernel.netlink.Close()
	return nil
}

func (kernel *Kernel) Start(config Config) (retErr error) {
	link, err := kernel.resolveInterface(config.RouteProbe)
	if err != nil {
		return err
	}
	uids, err := resolveUsers(config.Users)
	if err != nil {
		return err
	}
	if err := deleteMarkTable(); err != nil {
		return err
	}
	if err := kernel.deleteRoot(link); err != nil {
		return err
	}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, deleteMarkTable(), kernel.deleteRoot(link))
		}
	}()
	if err := addMarkTable(uids, config.Mark); err != nil {
		return err
	}
	return kernel.addTrafficControl(link, config.Topology())
}

func (kernel *Kernel) Stop(config Config) error {
	link, err := kernel.resolveInterface(config.RouteProbe)
	if err != nil {
		return err
	}
	return errors.Join(deleteMarkTable(), kernel.deleteRoot(link))
}

func (kernel *Kernel) resolveInterface(routeProbe string) (netlink.Link, error) {
	routes, err := kernel.netlink.RouteGet(net.ParseIP(routeProbe))
	if err != nil {
		return nil, fmt.Errorf("resolve route to %s: %w", routeProbe, err)
	}
	if len(routes) == 0 || routes[0].LinkIndex == 0 {
		return nil, fmt.Errorf("route to %s has no output interface", routeProbe)
	}
	link, err := kernel.netlink.LinkByIndex(routes[0].LinkIndex)
	if err != nil {
		return nil, fmt.Errorf("find route output interface %d: %w", routes[0].LinkIndex, err)
	}
	return link, nil
}

func resolveUsers(names []string) ([]uint32, error) {
	uids := make([]uint32, 0, len(names))
	for _, name := range names {
		account, err := user.Lookup(name)
		if err != nil {
			return nil, fmt.Errorf("look up user %s: %w", name, err)
		}
		uid, err := strconv.ParseUint(account.Uid, 10, 32)
		if err != nil {
			return nil, fmt.Errorf("parse UID for user %s: %w", name, err)
		}
		uids = append(uids, uint32(uid))
	}
	return uids, nil
}

func deleteMarkTable() error {
	connection := &nftables.Conn{}
	tables, err := connection.ListTables()
	if err != nil {
		return fmt.Errorf("list nftables tables: %w", err)
	}
	for _, table := range tables {
		if table.Family == nftables.TableFamilyINet && table.Name == tableName {
			connection.DelTable(table)
			if err := connection.Flush(); err != nil {
				return fmt.Errorf("delete nftables table %s: %w", tableName, err)
			}
			return nil
		}
	}
	return nil
}

func addMarkTable(uids []uint32, mark uint32) error {
	connection := &nftables.Conn{}
	table := connection.AddTable(&nftables.Table{
		Family: nftables.TableFamilyINet,
		Name:   tableName,
	})
	policy := nftables.ChainPolicyAccept
	chain := connection.AddChain(&nftables.Chain{
		Name:     chainName,
		Table:    table,
		Type:     nftables.ChainTypeRoute,
		Hooknum:  nftables.ChainHookOutput,
		Priority: nftables.ChainPriorityMangle,
		Policy:   &policy,
	})
	for _, uid := range uids {
		connection.AddRule(&nftables.Rule{
			Table: table,
			Chain: chain,
			Exprs: markExpressions(uid, mark),
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

func (kernel *Kernel) addTrafficControl(link netlink.Link, topology Topology) error {
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
	for _, filter := range topology.Filters {
		if err := kernel.addFilter(link, filter); err != nil {
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
	htbClass := netlink.NewHtbClass(
		netlink.ClassAttrs{
			LinkIndex: link.Attrs().Index,
			Handle:    netlink.MakeHandle(1, class.Minor),
			Parent:    parent,
		},
		netlink.HtbClassAttrs{Rate: class.RateBits, Ceil: class.RateBits},
	)
	if err := kernel.netlink.ClassAdd(htbClass); err != nil {
		return fmt.Errorf("add HTB class 1:%x on %s: %w", class.Minor, link.Attrs().Name, err)
	}
	if class.Minor == rootClassMinor {
		return nil
	}
	qdisc := netlink.NewFqCodel(netlink.QdiscAttrs{
		LinkIndex: link.Attrs().Index,
		Handle:    netlink.MakeHandle(class.Minor, 0),
		Parent:    netlink.MakeHandle(1, class.Minor),
	})
	if err := kernel.netlink.QdiscAdd(qdisc); err != nil {
		return fmt.Errorf("add fq_codel for class 1:%x on %s: %w", class.Minor, link.Attrs().Name, err)
	}
	return nil
}

func (kernel *Kernel) addFilter(link netlink.Link, filter Filter) error {
	fw := &netlink.FwFilter{
		FilterAttrs: netlink.FilterAttrs{
			LinkIndex: link.Attrs().Index,
			Handle:    filter.Mark,
			Parent:    netlink.MakeHandle(1, 0),
			Priority:  filter.Priority,
			Protocol:  filter.Protocol,
		},
		ClassId: netlink.MakeHandle(1, filter.Class),
	}
	if err := kernel.netlink.FilterAdd(fw); err != nil {
		return fmt.Errorf("add priority %d fw filter on %s: %w", filter.Priority, link.Attrs().Name, err)
	}
	return nil
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

func isMissing(err error) bool {
	return errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ENODEV) || errors.Is(err, unix.EINVAL)
}
