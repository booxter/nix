package dashboards

import "testing"

func TestDecodeConfig(t *testing.T) {
	config, err := DecodeConfigString(`{
  "dataSources": {
    "prometheus": {
      "type": "prometheus",
      "uid": "prometheus-uid"
    },
    "loki": {
      "type": "loki",
      "uid": "loki-uid"
    }
  },
  "network": {
    "internet": {
      "ingress": {"capacityMbit": 1000, "targetMbit": 400},
      "egress": {"capacityMbit": 40, "targetMbit": 25}
    }
  },
  "hosts": [
    {
      "name": "frame",
      "platform": "linux",
      "gpuVendor": null,
      "services": [],
      "diskBays": null,
      "backupServer": false,
      "virtual": false,
      "builder": true,
      "hypervisor": false
    }
  ]
}`)
	if err != nil {
		t.Fatalf("DecodeConfigString() error = %v", err)
	}
	if config.DataSources.Prometheus.UID != "prometheus-uid" {
		t.Fatalf("Prometheus UID = %q", config.DataSources.Prometheus.UID)
	}
}

func TestDecodeConfigRejectsMissingPrometheusUID(t *testing.T) {
	_, err := DecodeConfigString(`{
  "dataSources": {
    "prometheus": {
      "type": "prometheus",
      "uid": ""
    },
    "loki": {
      "type": "loki",
      "uid": "loki-uid"
    }
  },
  "network": {
    "internet": {
      "ingress": {"capacityMbit": 1000, "targetMbit": 400},
      "egress": {"capacityMbit": 40, "targetMbit": 25}
    }
  },
  "hosts": [
    {
      "name": "frame",
      "platform": "linux",
      "gpuVendor": null,
      "services": [],
      "diskBays": null,
      "backupServer": false,
      "virtual": false,
      "builder": true,
      "hypervisor": false
    }
  ]
}`)
	if err == nil {
		t.Fatal("DecodeConfigString() accepted an empty Prometheus UID")
	}
}
