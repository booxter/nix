package statuspage

import (
	"encoding/json"
	"fmt"
)

type incidentIOGroup struct {
	Name       string `json:"name"`
	Hidden     bool   `json:"hidden"`
	Components []struct {
		ID     string `json:"component_id"`
		Hidden bool   `json:"hidden"`
	} `json:"components"`
}

func decodeIncidentIOSummary(body []byte) (Summary, error) {
	var response struct {
		Summary struct {
			AffectedComponents []struct {
				ID     string `json:"component_id"`
				Status any    `json:"status"`
			} `json:"affected_components"`
			OngoingIncidents []json.RawMessage `json:"ongoing_incidents"`
			Structure        struct {
				Items []struct {
					Group *incidentIOGroup `json:"group"`
				} `json:"items"`
			} `json:"structure"`
		} `json:"summary"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return Summary{}, fmt.Errorf("decode incident.io summary: %w", err)
	}
	page := response.Summary
	if page.AffectedComponents == nil || page.Structure.Items == nil {
		return Summary{}, fmt.Errorf("decode incident.io summary: unexpected structure")
	}

	groupByComponent := make(map[string]string)
	for _, item := range page.Structure.Items {
		group := item.Group
		if group == nil || group.Hidden {
			continue
		}
		for _, component := range group.Components {
			if !component.Hidden {
				groupByComponent[component.ID] = group.Name
			}
		}
	}

	// The feed lists only affected components. Give each one its group name
	// so the shared filter can match an issue anywhere in a watched group.
	summary := Summary{Indicator: "none", Incidents: len(page.OngoingIncidents)}
	for _, component := range page.AffectedComponents {
		summary.Components = append(summary.Components, Component{
			Name:   groupByComponent[component.ID],
			Status: component.Status,
		})
	}
	return summary, nil
}
