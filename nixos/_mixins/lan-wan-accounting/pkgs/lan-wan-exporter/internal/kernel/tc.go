package kernel

import (
	"fmt"
	"net"
	"strconv"
	"strings"

	tc "github.com/florianl/go-tc"
	"golang.org/x/sys/unix"
)

type TCClasses struct{}

func (TCClasses) Bytes(interfaceName, classID string) (uint64, error) {
	device, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return 0, fmt.Errorf("find interface %s: %w", interfaceName, err)
	}
	handle, err := parseClassID(classID)
	if err != nil {
		return 0, err
	}
	connection, err := tc.Open(&tc.Config{})
	if err != nil {
		return 0, fmt.Errorf("open traffic-control netlink connection: %w", err)
	}
	defer connection.Close()
	classes, err := connection.Class().Get(&tc.Msg{
		Family:  uint32(unix.AF_UNSPEC),
		Ifindex: uint32(device.Index),
	})
	if err != nil {
		return 0, fmt.Errorf("list classes on %s: %w", interfaceName, err)
	}
	return classBytes(classes, handle), nil
}

func parseClassID(classID string) (uint32, error) {
	parts := strings.Split(classID, ":")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return 0, fmt.Errorf("invalid traffic-control class ID %q", classID)
	}
	major, err := strconv.ParseUint(parts[0], 16, 16)
	if err != nil {
		return 0, fmt.Errorf("invalid traffic-control class ID %q: %w", classID, err)
	}
	minor, err := strconv.ParseUint(parts[1], 16, 16)
	if err != nil {
		return 0, fmt.Errorf("invalid traffic-control class ID %q: %w", classID, err)
	}
	return uint32(major<<16 | minor), nil
}

func classBytes(classes []tc.Object, handle uint32) uint64 {
	for _, class := range classes {
		if class.Handle != handle {
			continue
		}
		if class.Stats2 != nil {
			return class.Stats2.Bytes
		}
		if class.Stats != nil {
			return class.Stats.Bytes
		}
	}
	return 0
}
