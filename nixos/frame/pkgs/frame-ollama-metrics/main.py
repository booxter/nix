import argparse
import datetime
import json
import math
import os
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class PrometheusText:
    def __init__(self):
        self.lines = []
        self.declared = set()

    def metric(self, name, help_text, metric_type, value, labels=None):
        if value is None:
            return
        if isinstance(value, float) and not math.isfinite(value):
            return
        if name not in self.declared:
            self.lines.append(f"# HELP {name} {help_text}")
            self.lines.append(f"# TYPE {name} {metric_type}")
            self.declared.add(name)
        label_text = ""
        if labels:
            pairs = [f'{key}="{prom_escape(val)}"' for key, val in labels.items()]
            label_text = "{" + ",".join(pairs) + "}"
        self.lines.append(f"{name}{label_text} {value}")

    def render(self):
        return "\n".join(self.lines) + "\n"


def parse_timestamp(value):
    if not value:
        return None
    if isinstance(value, (int, float)):
        return value
    try:
        normalized = str(value).replace("Z", "+00:00")
        return datetime.datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return None


def get_json(base_url, path, timeout):
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def model_labels(model):
    details = model.get("details") or {}
    return {
        "model": model.get("model") or model.get("name") or "unknown",
        "family": details.get("family") or "",
        "format": details.get("format") or "",
        "parameter_size": details.get("parameter_size") or "",
        "quantization_level": details.get("quantization_level") or "",
    }


def collect_metrics(base_url, timeout):
    start = time.monotonic()
    out = PrometheusText()
    version = get_json(base_url, "/api/version", timeout)
    tags = get_json(base_url, "/api/tags", timeout)
    running = get_json(base_url, "/api/ps", timeout)
    duration = time.monotonic() - start
    models = tags.get("models") or []
    running_models = running.get("models") or []

    out.metric(
        "host_observability_ollama_collector_ok",
        "Whether the latest Ollama metrics collection iteration succeeded.",
        "gauge",
        1,
    )
    out.metric(
        "host_observability_ollama_collector_duration_seconds",
        "Wall-clock duration of the latest Ollama metrics collection iteration.",
        "gauge",
        duration,
    )
    out.metric(
        "host_observability_ollama_up",
        "Whether the local Ollama API is reachable.",
        "gauge",
        1,
    )
    out.metric(
        "host_observability_ollama_info",
        "Static Ollama service information.",
        "gauge",
        1,
        {"version": version.get("version") or ""},
    )
    out.metric(
        "host_observability_ollama_models",
        "Number of locally installed Ollama models.",
        "gauge",
        len(models),
    )
    out.metric(
        "host_observability_ollama_running_models",
        "Number of currently loaded Ollama models.",
        "gauge",
        len(running_models),
    )

    for model in models:
        labels = model_labels(model)
        out.metric(
            "host_observability_ollama_model_info",
            "Static Ollama model information.",
            "gauge",
            1,
            labels,
        )
        out.metric(
            "host_observability_ollama_model_size_bytes",
            "Local Ollama model size in bytes.",
            "gauge",
            model.get("size"),
            {"model": labels["model"]},
        )
        out.metric(
            "host_observability_ollama_model_modified_timestamp_seconds",
            "Unix timestamp when the local Ollama model was last modified.",
            "gauge",
            parse_timestamp(model.get("modified_at")),
            {"model": labels["model"]},
        )

        details = model.get("details") or {}
        out.metric(
            "host_observability_ollama_model_context_length",
            "Ollama model context length.",
            "gauge",
            details.get("context_length"),
            {"model": labels["model"]},
        )
        out.metric(
            "host_observability_ollama_model_embedding_length",
            "Ollama model embedding length.",
            "gauge",
            details.get("embedding_length"),
            {"model": labels["model"]},
        )
        for capability in model.get("capabilities") or []:
            out.metric(
                "host_observability_ollama_model_capability",
                "Ollama model capability flag.",
                "gauge",
                1,
                {"model": labels["model"], "capability": capability},
            )

    for model in running_models:
        labels = model_labels(model)
        out.metric(
            "host_observability_ollama_running_model_info",
            "Currently loaded Ollama model information.",
            "gauge",
            1,
            labels,
        )
        for key, metric_suffix, help_text in [
            ("size", "size_bytes", "Loaded Ollama model total size in bytes."),
            ("size_vram", "vram_size_bytes", "Loaded Ollama model VRAM size in bytes."),
        ]:
            out.metric(
                f"host_observability_ollama_running_model_{metric_suffix}",
                help_text,
                "gauge",
                model.get(key),
                {"model": labels["model"]},
            )
        out.metric(
            "host_observability_ollama_running_model_expires_timestamp_seconds",
            "Unix timestamp when the loaded Ollama model is scheduled to unload.",
            "gauge",
            parse_timestamp(model.get("expires_at")),
            {"model": labels["model"]},
        )

    return out.render()


def failure_metrics(duration):
    out = PrometheusText()
    out.metric(
        "host_observability_ollama_collector_ok",
        "Whether the latest Ollama metrics collection iteration succeeded.",
        "gauge",
        0,
    )
    out.metric(
        "host_observability_ollama_collector_duration_seconds",
        "Wall-clock duration of the latest Ollama metrics collection iteration.",
        "gauge",
        duration,
    )
    out.metric(
        "host_observability_ollama_up",
        "Whether the local Ollama API is reachable.",
        "gauge",
        0,
    )
    return out.render()


def write_output(path, content):
    if path == "-":
        print(content, end="")
        return
    directory = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(
        prefix=f".{os.path.basename(path)}.", dir=directory, text=True
    )
    try:
        with os.fdopen(fd, "w") as tmp:
            tmp.write(content)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    finally:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:11434")
    parser.add_argument("--output", default="-")
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()

    start = time.monotonic()
    try:
        content = collect_metrics(args.base_url, args.timeout)
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        content = failure_metrics(time.monotonic() - start)
    write_output(args.output, content)


if __name__ == "__main__":
    main()
