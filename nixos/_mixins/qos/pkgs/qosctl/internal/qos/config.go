package qos

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
)

type Direction string

const (
	Egress  Direction = "egress"
	Ingress Direction = "ingress"
)

type LeafQdisc string

const (
	CakeQdisc    LeafQdisc = "cake"
	FqCodelQdisc LeafQdisc = "fq_codel"
)

type IPFamily string

const (
	BothFamilies IPFamily = "both"
	IPv4         IPFamily = "ipv4"
	IPv6         IPFamily = "ipv6"
)

type TransportProtocol string

const (
	TCP TransportProtocol = "tcp"
	UDP TransportProtocol = "udp"
)

type Config struct {
	Profile      string  `json:"profile"`
	Interface    string  `json:"interface"`
	NftTable     string  `json:"nftTable"`
	LinkRateBits uint64  `json:"linkRateBits"`
	Limits       []Limit `json:"limits"`
}

type Limit struct {
	Name         string    `json:"name"`
	Direction    Direction `json:"direction"`
	RateBits     uint64    `json:"rateBits"`
	Queue        LeafQdisc `json:"queue"`
	ClassMinor   uint16    `json:"classMinor"`
	IFBInterface string    `json:"ifbInterface"`
	Match        Match     `json:"match"`
}

type Match struct {
	Family             IPFamily          `json:"family"`
	Protocol           TransportProtocol `json:"protocol"`
	SourceAddress      string            `json:"sourceAddress"`
	DestinationAddress string            `json:"destinationAddress"`
	SourcePort         uint16            `json:"sourcePort"`
	DestinationPort    uint16            `json:"destinationPort"`
	Users              []string          `json:"users"`
}

func LoadConfig(path string) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, fmt.Errorf("open configuration: %w", err)
	}
	defer file.Close()

	config, err := decodeConfig(file)
	if err != nil {
		return Config{}, fmt.Errorf("load configuration: %w", err)
	}
	return config, nil
}

func decodeConfig(reader io.Reader) (Config, error) {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, err
	}
	if err := config.Validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

func (config Config) Validate() error {
	if config.Profile == "" {
		return fmt.Errorf("profile must not be empty")
	}
	if config.Interface == "" {
		return fmt.Errorf("interface must not be empty")
	}
	if config.NftTable == "" {
		return fmt.Errorf("nftTable must not be empty")
	}
	if config.LinkRateBits == 0 {
		return fmt.Errorf("linkRateBits must be positive")
	}
	if len(config.Limits) == 0 {
		return fmt.Errorf("limits must not be empty")
	}

	names := make(map[string]struct{}, len(config.Limits))
	classes := make(map[uint16]string, len(config.Limits))
	ifbs := make(map[string]string, len(config.Limits))
	for _, limit := range config.Limits {
		if limit.Name == "" {
			return fmt.Errorf("limit name must not be empty")
		}
		if _, exists := names[limit.Name]; exists {
			return fmt.Errorf("limit %q is configured more than once", limit.Name)
		}
		names[limit.Name] = struct{}{}
		if limit.RateBits == 0 || limit.RateBits > config.LinkRateBits {
			return fmt.Errorf("limit %q rate must be positive and cannot exceed linkRateBits", limit.Name)
		}
		if limit.Queue != CakeQdisc && limit.Queue != FqCodelQdisc {
			return fmt.Errorf("limit %q has unsupported queue %q", limit.Name, limit.Queue)
		}
		if err := limit.Match.validate(limit.Name); err != nil {
			return err
		}

		switch limit.Direction {
		case Egress:
			if limit.ClassMinor == 0 {
				return fmt.Errorf("egress limit %q requires classMinor", limit.Name)
			}
			if previous, exists := classes[limit.ClassMinor]; exists {
				return fmt.Errorf("limits %q and %q use the same classMinor", previous, limit.Name)
			}
			classes[limit.ClassMinor] = limit.Name
			if limit.IFBInterface != "" {
				return fmt.Errorf("egress limit %q must not define ifbInterface", limit.Name)
			}
		case Ingress:
			if len(limit.Match.Users) != 0 {
				return fmt.Errorf("ingress limit %q cannot match users", limit.Name)
			}
			if limit.ClassMinor != 0 {
				return fmt.Errorf("ingress limit %q must not define classMinor", limit.Name)
			}
			if limit.IFBInterface == "" || len(limit.IFBInterface) > 15 {
				return fmt.Errorf("ingress limit %q requires an IFB interface of at most 15 characters", limit.Name)
			}
			if previous, exists := ifbs[limit.IFBInterface]; exists {
				return fmt.Errorf("limits %q and %q use the same IFB interface", previous, limit.Name)
			}
			ifbs[limit.IFBInterface] = limit.Name
			if limit.Queue != CakeQdisc {
				return fmt.Errorf("ingress limit %q currently requires the cake queue", limit.Name)
			}
		default:
			return fmt.Errorf("limit %q has unsupported direction %q", limit.Name, limit.Direction)
		}
	}
	return nil
}

func (match Match) validate(limitName string) error {
	if match.Family != BothFamilies && match.Family != IPv4 && match.Family != IPv6 {
		return fmt.Errorf("limit %q has unsupported address family %q", limitName, match.Family)
	}
	if len(match.Users) != 0 {
		if match.Protocol != "" || match.SourceAddress != "" || match.DestinationAddress != "" ||
			match.SourcePort != 0 || match.DestinationPort != 0 {
			return fmt.Errorf("limit %q cannot combine users with packet fields", limitName)
		}
		seen := make(map[string]struct{}, len(match.Users))
		for _, name := range match.Users {
			if name == "" {
				return fmt.Errorf("limit %q users must not contain an empty name", limitName)
			}
			if _, exists := seen[name]; exists {
				return fmt.Errorf("limit %q user %q is configured more than once", limitName, name)
			}
			seen[name] = struct{}{}
		}
		return nil
	}
	if match.Protocol != TCP && match.Protocol != UDP {
		return fmt.Errorf("limit %q requires protocol tcp or udp", limitName)
	}
	for field, value := range map[string]string{
		"sourceAddress":      match.SourceAddress,
		"destinationAddress": match.DestinationAddress,
	} {
		if value == "" {
			continue
		}
		address := net.ParseIP(value)
		if address == nil {
			return fmt.Errorf("limit %q %s must be an IP address", limitName, field)
		}
		if match.Family == IPv4 && address.To4() == nil {
			return fmt.Errorf("limit %q %s does not match family ipv4", limitName, field)
		}
		if match.Family == IPv6 && address.To4() != nil {
			return fmt.Errorf("limit %q %s does not match family ipv6", limitName, field)
		}
	}
	if match.SourceAddress != "" && match.DestinationAddress != "" {
		sourceV4 := net.ParseIP(match.SourceAddress).To4() != nil
		destinationV4 := net.ParseIP(match.DestinationAddress).To4() != nil
		if sourceV4 != destinationV4 {
			return fmt.Errorf("limit %q source and destination addresses use different families", limitName)
		}
	}
	return nil
}

func (config Config) Limit(name string) (Limit, error) {
	for _, limit := range config.Limits {
		if limit.Name == name {
			return limit, nil
		}
	}
	return Limit{}, fmt.Errorf("limit %q is not configured", name)
}
