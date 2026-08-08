package dashboards

import "testing"

func TestDecodeConfig(t *testing.T) {
	config, err := DecodeConfigString(`{
  "dataSources": {
    "prometheus": {
      "type": "prometheus",
      "uid": "prometheus-uid"
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
      "capacityProfile": "cpu-bursty",
      "thermalProfile": "standard",
      "gpuVendor": null,
      "services": [],
      "storage": {},
      "backups": {},
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
      "capacityProfile": "cpu-bursty",
      "thermalProfile": "standard",
      "gpuVendor": null,
      "services": [],
      "storage": {},
      "backups": {},
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
