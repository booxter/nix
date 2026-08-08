package accounting

import (
	"fmt"

	"github.com/prometheus/client_golang/prometheus"
)

const (
	networkMetricName  = "host_observability_network_bytes_total"
	subclassMetricName = "host_observability_network_wan_subclass_bytes_total"
)

type CounterSource interface {
	Counters(table string) (map[string]uint64, error)
}

type ClassSource interface {
	Bytes(interfaceName, classID string) (uint64, error)
}

type Config struct {
	Table     string
	Subclass  string
	Interface string
	TCClass   string
}

func (c Config) validate() error {
	if c.Table == "" {
		return fmt.Errorf("nftables table is required")
	}
	if (c.Interface == "") != (c.TCClass == "") {
		return fmt.Errorf("interface and tc class must be configured together")
	}
	if c.TCClass != "" && c.Subclass == "" {
		return fmt.Errorf("tc override requires a WAN subclass")
	}
	return nil
}

type Snapshot struct {
	LANReceive    uint64
	WANReceive    uint64
	LANTransmit   uint64
	WANTransmit   uint64
	Subclass      string
	SubclassBytes uint64
	OtherWANBytes uint64
}

func Collect(counters CounterSource, classes ClassSource, configuration Config) (Snapshot, error) {
	if err := configuration.validate(); err != nil {
		return Snapshot{}, err
	}
	values, err := counters.Counters(configuration.Table)
	if err != nil {
		return Snapshot{}, fmt.Errorf("read nftables counters: %w", err)
	}
	snapshot := Snapshot{
		LANReceive:  values["lan_in"],
		WANReceive:  values["wan_in"],
		LANTransmit: values["lan_out"],
		WANTransmit: values["wan_out"],
		Subclass:    configuration.Subclass,
	}
	if configuration.Subclass != "" {
		snapshot.SubclassBytes = values[configuration.Subclass+"_out"]
		snapshot.OtherWANBytes = values["wan_other_out"]
	}
	if configuration.TCClass != "" {
		classBytes, err := classes.Bytes(configuration.Interface, configuration.TCClass)
		if err != nil {
			return Snapshot{}, fmt.Errorf("read traffic-control class: %w", err)
		}
		snapshot.SubclassBytes = classBytes
		snapshot.WANTransmit = classBytes + snapshot.OtherWANBytes
	}
	return snapshot, nil
}

type collector struct {
	snapshot *Snapshot
	network  *prometheus.Desc
	subclass *prometheus.Desc
}

func NewCollector(snapshot Snapshot) prometheus.Collector {
	return &collector{
		snapshot: &snapshot,
		network: prometheus.NewDesc(
			networkMetricName,
			"Classified network traffic observed on this host (per packet path/interface) in bytes.",
			[]string{"direction", "scope"},
			nil,
		),
		subclass: prometheus.NewDesc(
			subclassMetricName,
			"Classified outbound WAN traffic in bytes by subclass.",
			[]string{"class"},
			nil,
		),
	}
}

func (c *collector) Describe(descriptions chan<- *prometheus.Desc) {
	descriptions <- c.network
	descriptions <- c.subclass
}

func (c *collector) Collect(metrics chan<- prometheus.Metric) {
	for _, metric := range []struct {
		direction string
		scope     string
		value     uint64
	}{
		{direction: "receive", scope: "lan", value: c.snapshot.LANReceive},
		{direction: "receive", scope: "wan", value: c.snapshot.WANReceive},
		{direction: "transmit", scope: "lan", value: c.snapshot.LANTransmit},
		{direction: "transmit", scope: "wan", value: c.snapshot.WANTransmit},
	} {
		metrics <- prometheus.MustNewConstMetric(
			c.network,
			prometheus.CounterValue,
			float64(metric.value),
			metric.direction,
			metric.scope,
		)
	}
	if c.snapshot.Subclass != "" {
		metrics <- prometheus.MustNewConstMetric(
			c.subclass,
			prometheus.CounterValue,
			float64(c.snapshot.SubclassBytes),
			c.snapshot.Subclass,
		)
		metrics <- prometheus.MustNewConstMetric(
			c.subclass,
			prometheus.CounterValue,
			float64(c.snapshot.OtherWANBytes),
			"other",
		)
	}
}

func Registry(snapshot Snapshot) *prometheus.Registry {
	registry := prometheus.NewRegistry()
	registry.MustRegister(NewCollector(snapshot))
	return registry
}

func WriteTextfile(path string, snapshot Snapshot) error {
	return prometheus.WriteToTextfile(path, Registry(snapshot))
}
