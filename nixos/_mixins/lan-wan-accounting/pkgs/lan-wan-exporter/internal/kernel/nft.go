package kernel

import (
	"fmt"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
)

type NFTCounters struct{}

func (NFTCounters) Counters(tableName string) (map[string]uint64, error) {
	connection, err := nftables.New()
	if err != nil {
		return nil, fmt.Errorf("open nftables netlink connection: %w", err)
	}
	objects, err := connection.GetNamedObjects(&nftables.Table{
		Family: nftables.TableFamilyINet,
		Name:   tableName,
	})
	if err != nil {
		return nil, fmt.Errorf("list named objects: %w", err)
	}
	return counterValues(objects)
}

func counterValues(objects []nftables.Obj) (map[string]uint64, error) {
	values := make(map[string]uint64)
	for _, object := range objects {
		named, ok := object.(*nftables.NamedObj)
		if !ok || named.Type != nftables.ObjTypeCounter {
			continue
		}
		counter, ok := named.Obj.(*expr.Counter)
		if !ok {
			return nil, fmt.Errorf("nftables counter %s has unexpected data %T", named.Name, named.Obj)
		}
		values[named.Name] = counter.Bytes
	}
	return values, nil
}
