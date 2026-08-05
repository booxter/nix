package qos

import (
	"strings"
	"testing"
)

func TestDecodeConfigRejectsUnknownAndInvalidFields(t *testing.T) {
	for name, document := range map[string]string{
		"unknown field": `{
			"routeProbe":"1.1.1.1","users":["restic-cloud"],"mark":1,
			"outerRateBits":10000000000,"cloudRateBits":10000000,"typo":true}`,
		"invalid route": `{
			"routeProbe":"not-an-address","users":["restic-cloud"],"mark":1,
			"outerRateBits":10000000000,"cloudRateBits":10000000}`,
		"empty users": `{
			"routeProbe":"1.1.1.1","users":[],"mark":1,
			"outerRateBits":10000000000,"cloudRateBits":10000000}`,
		"duplicate user": `{
			"routeProbe":"1.1.1.1","users":["restic-cloud","restic-cloud"],"mark":1,
			"outerRateBits":10000000000,"cloudRateBits":10000000}`,
		"cloud rate above link": `{
			"routeProbe":"1.1.1.1","users":["restic-cloud"],"mark":1,
			"outerRateBits":10000000,"cloudRateBits":10000001}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeConfig(strings.NewReader(document)); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

func TestTopologyPreservesCloudShapingClassesAndFilters(t *testing.T) {
	config := Config{
		RouteProbe:    "1.1.1.1",
		Users:         []string{"restic-cloud", "restic-org-offload"},
		Mark:          1,
		OuterRateBits: 10_000_000_000,
		CloudRateBits: 10_000_000,
	}
	if err := config.Validate(); err != nil {
		t.Fatal(err)
	}
	topology := config.Topology()
	assertClass(t, topology, rootClassMinor, 0, 10_000_000_000)
	assertClass(t, topology, cloudClassMinor, rootClassMinor, 10_000_000)
	assertClass(t, topology, defaultClassMinor, rootClassMinor, 10_000_000_000)
	assertFilter(t, topology, ethernetProtocolIPv4, 10, 1, cloudClassMinor)
	assertFilter(t, topology, ethernetProtocolIPv6, 11, 1, cloudClassMinor)
}

func assertClass(t *testing.T, topology Topology, minor, parent uint16, rate uint64) {
	t.Helper()
	for _, class := range topology.Classes {
		if class.Minor == minor {
			if class.Parent != parent || class.RateBits != rate {
				t.Fatalf("unexpected class 1:%x: %#v", minor, class)
			}
			return
		}
	}
	t.Fatalf("class 1:%x not found", minor)
}

func assertFilter(
	t *testing.T,
	topology Topology,
	protocol uint16,
	priority uint16,
	mark uint32,
	class uint16,
) {
	t.Helper()
	for _, filter := range topology.Filters {
		if filter.Protocol == protocol && filter.Priority == priority &&
			filter.Mark == mark && filter.Class == class {
			return
		}
	}
	t.Fatalf(
		"filter not found: protocol=%d priority=%d mark=%d class=1:%x",
		protocol,
		priority,
		mark,
		class,
	)
}
