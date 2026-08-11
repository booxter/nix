//go:build linux

package bridgeaccess

import "net/netip"

type Rule struct {
	Handle        uint64
	SourceAddress netip.Addr
	TCPPort       uint16
}

type ruleKey struct {
	SourceAddress netip.Addr
	TCPPort       uint16
}

func (rule Rule) key() ruleKey {
	return ruleKey{SourceAddress: rule.SourceAddress, TCPPort: rule.TCPPort}
}

type RuleStore interface {
	ListOwned() ([]Rule, error)
	Insert(Rule)
	Delete(Rule)
	Flush() error
}

func Apply(config Config, store RuleStore) error {
	if err := config.validate(); err != nil {
		return err
	}
	existing, err := store.ListOwned()
	if err != nil {
		return err
	}
	desired := make(map[ruleKey]struct{}, len(config.TCPPorts))
	for _, port := range config.TCPPorts {
		desired[ruleKey{SourceAddress: config.SourceAddress, TCPPort: port}] = struct{}{}
	}

	kept := make(map[ruleKey]struct{}, len(desired))
	changed := false
	for _, rule := range existing {
		key := rule.key()
		_, wanted := desired[key]
		_, duplicate := kept[key]
		if !wanted || duplicate {
			store.Delete(rule)
			changed = true
			continue
		}
		kept[key] = struct{}{}
	}
	for key := range desired {
		if _, exists := kept[key]; exists {
			continue
		}
		store.Insert(Rule{SourceAddress: key.SourceAddress, TCPPort: key.TCPPort})
		changed = true
	}
	if !changed {
		return nil
	}
	return store.Flush()
}

func Remove(store RuleStore) error {
	existing, err := store.ListOwned()
	if err != nil {
		return err
	}
	if len(existing) == 0 {
		return nil
	}
	for _, rule := range existing {
		store.Delete(rule)
	}
	return store.Flush()
}
