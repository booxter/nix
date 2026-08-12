package networkstatus

import "github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"

const (
	vpnIcon          = "􀎠"
	connectedIcon    = "􀙇"
	disconnectedIcon = "􀇿"
)

func Run(config Config, provider InterfaceProvider, bar sketchybar.Runner) error {
	interfaces, err := provider.Interfaces()
	if err != nil {
		interfaces = nil
	}
	status := Detect(interfaces)
	icon := disconnectedIcon
	label := "Not Connected"
	if status.VPN {
		icon = vpnIcon
		label = status.Address
		if label == "" {
			label = "VPN"
		}
	} else if status.Address != "" {
		icon = connectedIcon
		label = status.Address
	}

	arguments := []string{"--set", config.Name, "icon=" + icon, "label=" + label}
	if config.Sender == "mouse.clicked" {
		arguments = append(arguments, "label.drawing=toggle")
	}
	return bar.Run(arguments...)
}
