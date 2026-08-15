package stock

import (
	"context"
	"strconv"
	"strings"

	"github.com/booxter/nix-config/sketchybar-tools/internal/sketchybar"
)

const (
	upIcon          = "􀁧"
	downIcon        = "􀁩"
	unavailableIcon = "􀇿"
)

type QuoteFetcher interface {
	Fetch(context.Context) (Quote, error)
}

func Run(ctx context.Context, config Config, fetcher QuoteFetcher, bar sketchybar.Runner) error {
	quote, err := fetcher.Fetch(ctx)
	if err != nil {
		return bar.Run(
			"--set", config.Name,
			"icon="+unavailableIcon,
			"icon.color="+config.Yellow,
			"label="+config.Symbol,
		)
	}

	icon := upIcon
	color := config.Green
	if quote.Direction == "down" {
		icon = downIcon
		color = config.Red
	}
	return bar.Run(
		"--set", config.Name,
		"icon="+icon,
		"icon.color="+color,
		"label="+formatPrice(quote.LastSalePrice),
	)
}

func formatPrice(price string) string {
	prefix := ""
	if strings.HasPrefix(price, "$") {
		prefix = "$"
	}
	numeric := strings.NewReplacer(",", "", "$", "").Replace(price)
	numeric = strings.Join(strings.Fields(numeric), "")
	value, err := strconv.ParseFloat(numeric, 64)
	if err != nil {
		return price
	}
	return prefix + strconv.FormatFloat(value, 'f', 2, 64)
}
