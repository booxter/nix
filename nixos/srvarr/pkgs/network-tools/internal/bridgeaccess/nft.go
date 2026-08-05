//go:build linux

package bridgeaccess

import (
	"encoding/binary"
	"fmt"
	"net/netip"
	"strconv"
	"strings"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"
)

const ownerPrefix = "nix-config:wg-bridge-access:v1:"

type NFTStore struct {
	connection *nftables.Conn
	table      *nftables.Table
	chain      *nftables.Chain
}

func OpenNFTStore(namespace string) (*NFTStore, error) {
	namespaceHandle, err := netns.GetFromName(namespace)
	if err != nil {
		return nil, fmt.Errorf("open network namespace %s: %w", namespace, err)
	}
	defer namespaceHandle.Close()

	connection, err := nftables.New(
		nftables.WithNetNSFd(int(namespaceHandle)),
		nftables.AsLasting(),
	)
	if err != nil {
		return nil, fmt.Errorf("connect to nftables in namespace %s: %w", namespace, err)
	}
	closeOnError := func(err error) (*NFTStore, error) {
		_ = connection.CloseLasting()
		return nil, err
	}
	table, err := connection.ListTableOfFamily("filter", nftables.TableFamilyIPv4)
	if err != nil {
		return closeOnError(fmt.Errorf("find IPv4 filter table: %w", err))
	}
	chain, err := connection.ListChain(table, "INPUT")
	if err != nil {
		return closeOnError(fmt.Errorf("find filter INPUT chain: %w", err))
	}
	return &NFTStore{connection: connection, table: table, chain: chain}, nil
}

func (store *NFTStore) Close() {
	_ = store.connection.CloseLasting()
}

func encodeOwner(rule Rule) []byte {
	return fmt.Appendf(nil, "%s%s:%d", ownerPrefix, rule.SourceAddress, rule.TCPPort)
}

func decodeOwner(data []byte) (Rule, bool) {
	encoded := string(data)
	if !strings.HasPrefix(encoded, ownerPrefix) {
		return Rule{}, false
	}
	addressText, portText, found := strings.Cut(strings.TrimPrefix(encoded, ownerPrefix), ":")
	if !found {
		return Rule{}, false
	}
	address, err := netip.ParseAddr(addressText)
	if err != nil || !address.Is4() {
		return Rule{}, false
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 {
		return Rule{}, false
	}
	return Rule{SourceAddress: address, TCPPort: uint16(port)}, true
}

func (store *NFTStore) ListOwned() ([]Rule, error) {
	rules, err := store.connection.GetRules(store.table, store.chain)
	if err != nil {
		return nil, fmt.Errorf("list filter INPUT rules: %w", err)
	}
	owned := make([]Rule, 0)
	for _, nftRule := range rules {
		rule, ok := decodeOwner(nftRule.UserData)
		if !ok {
			continue
		}
		rule.Handle = nftRule.Handle
		owned = append(owned, rule)
	}
	return owned, nil
}

func (store *NFTStore) Insert(rule Rule) {
	port := make([]byte, 2)
	binary.BigEndian.PutUint16(port, rule.TCPPort)
	source := rule.SourceAddress.As4()
	store.connection.InsertRule(&nftables.Rule{
		Table: store.table,
		Chain: store.chain,
		Exprs: []expr.Any{
			&expr.Meta{Key: expr.MetaKeyL4PROTO, Register: 1},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte{unix.IPPROTO_TCP}},
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 12, Len: 4},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: source[:]},
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseTransportHeader, Offset: 2, Len: 2},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: port},
			&expr.Verdict{Kind: expr.VerdictAccept},
		},
		UserData: encodeOwner(rule),
	})
}

func (store *NFTStore) Delete(rule Rule) {
	store.connection.DelRule(&nftables.Rule{
		Table:  store.table,
		Chain:  store.chain,
		Handle: rule.Handle,
	})
}

func (store *NFTStore) Flush() error {
	if err := store.connection.Flush(); err != nil {
		return fmt.Errorf("update filter INPUT rules: %w", err)
	}
	return nil
}
