package accounting

import (
	"errors"
	"testing"
)

type fixedCounters map[string]uint64

func (f fixedCounters) Counters(string) (map[string]uint64, error) {
	return f, nil
}

type fixedClass struct {
	bytes uint64
	err   error
}

func (f fixedClass) Bytes(string, string) (uint64, error) {
	return f.bytes, f.err
}

func TestCollectUsesNativeCounterValues(t *testing.T) {
	snapshot, err := Collect(
		fixedCounters{"lan_in": 10, "wan_in": 20, "lan_out": 30, "wan_out": 40},
		fixedClass{},
		Config{Table: "observability_lan_wan"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot != (Snapshot{LANReceive: 10, WANReceive: 20, LANTransmit: 30, WANTransmit: 40}) {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
}

func TestCollectUsesTCClassForSubclassAndWANTotal(t *testing.T) {
	snapshot, err := Collect(
		fixedCounters{
			"lan_in": 1, "wan_in": 2, "lan_out": 3, "wan_out": 999,
			"wg_out": 888, "wan_other_out": 25,
		},
		fixedClass{bytes: 100},
		Config{
			Table: "observability_lan_wan", Subclass: "wg",
			Interface: "ens18", TCClass: "1:10",
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.SubclassBytes != 100 || snapshot.OtherWANBytes != 25 || snapshot.WANTransmit != 125 {
		t.Fatalf("tc override was not applied: %#v", snapshot)
	}
}

func TestCollectPropagatesClassFailure(t *testing.T) {
	_, err := Collect(
		fixedCounters{},
		fixedClass{err: errors.New("netlink unavailable")},
		Config{Table: "table", Subclass: "wg", Interface: "ens18", TCClass: "1:10"},
	)
	if err == nil {
		t.Fatal("traffic-control failure unexpectedly accepted")
	}
}

func TestRegistryExposesStructuredMetrics(t *testing.T) {
	families, err := Registry(Snapshot{
		LANReceive: 10, WANReceive: 20, LANTransmit: 30, WANTransmit: 125,
		Subclass: "wg", SubclassBytes: 100, OtherWANBytes: 25,
	}).Gather()
	if err != nil {
		t.Fatal(err)
	}
	values := make(map[string]float64)
	for _, family := range families {
		for _, metric := range family.Metric {
			key := family.GetName()
			for _, label := range metric.Label {
				key += ":" + label.GetName() + "=" + label.GetValue()
			}
			values[key] = metric.GetCounter().GetValue()
		}
	}
	if values[networkMetricName+":direction=transmit:scope=wan"] != 125 {
		t.Fatalf("unexpected WAN metric families: %#v", values)
	}
	if values[subclassMetricName+":class=wg"] != 100 || values[subclassMetricName+":class=other"] != 25 {
		t.Fatalf("unexpected subclass metric families: %#v", values)
	}
}
