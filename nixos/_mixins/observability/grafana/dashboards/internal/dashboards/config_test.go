package dashboards

import "testing"

func TestDecodeConfig(t *testing.T) {
	config, err := DecodeConfigString(`{
  "dataSources": {
    "prometheus": {
      "type": "prometheus",
      "uid": "prometheus-uid"
    }
  }
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
  }
}`)
	if err == nil {
		t.Fatal("DecodeConfigString() accepted an empty Prometheus UID")
	}
}
