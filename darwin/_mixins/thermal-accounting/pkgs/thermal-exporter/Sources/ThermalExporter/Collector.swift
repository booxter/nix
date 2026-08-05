import Foundation

public struct ThermalSnapshot: Sendable {
  public let timestamp: Date
  public let pmset: String
  public let powermetrics: String
  public let powermetricsSucceeded: Bool
  public let ismc: Data
  public let ismcSucceeded: Bool

  public init(
    timestamp: Date,
    pmset: String,
    powermetrics: String,
    powermetricsSucceeded: Bool,
    ismc: Data,
    ismcSucceeded: Bool
  ) {
    self.timestamp = timestamp
    self.pmset = pmset
    self.powermetrics = powermetrics
    self.powermetricsSucceeded = powermetricsSucceeded
    self.ismc = ismc
    self.ismcSucceeded = ismcSucceeded
  }
}

public enum ThermalCollector {
  private static let prefix = "host_observability_darwin_"

  public static func collect(_ snapshot: ThermalSnapshot) throws -> MetricRegistry {
    var metrics = MetricRegistry()
    registerMetrics(&metrics)
    metrics.set(
      prefix + "thermal_warning_level",
      Double(pmsetLevel("thermal warning level", in: snapshot.pmset))
    )
    metrics.set(
      prefix + "performance_warning_level",
      Double(pmsetLevel("performance warning level", in: snapshot.pmset))
    )
    metrics.set(
      prefix + "cpu_power_status",
      Double(pmsetLevel("cpu power status", in: snapshot.pmset))
    )
    metrics.set(prefix + "powermetrics_collect_success", snapshot.powermetricsSucceeded ? 1 : 0)
    metrics.set(prefix + "ismc_collect_success", snapshot.ismcSucceeded ? 1 : 0)
    metrics.set(prefix + "powermetrics_sample_timestamp_seconds", snapshot.timestamp.timeIntervalSince1970)

    for reading in powerReadings(in: snapshot.powermetrics) {
      metrics.set(prefix + "power_watts", reading.watts, labels: [.init("domain", reading.domain)])
    }

    if snapshot.ismcSucceeded {
      let readings = try temperatureReadings(from: snapshot.ismc)
      var groupMaxima: [String: Double] = [:]
      var maximum: Double?
      for reading in readings {
        metrics.set(
          prefix + "temperature_celsius",
          reading.value,
          labels: [
            .init("sensor_name", reading.name),
            .init("sensor_key", reading.key),
            .init("sensor_type", reading.type),
            .init("sensor_group", reading.group),
          ]
        )
        maximum = max(maximum ?? reading.value, reading.value)
        updateMaximum(&groupMaxima, group: reading.group, value: reading.value)
        if reading.group == "cpu_perf" || reading.group == "cpu_eff" {
          updateMaximum(&groupMaxima, group: "cpu", value: reading.value)
        }
      }
      if let maximum {
        metrics.set(prefix + "temperature_max_celsius", maximum)
      }
      for group in groupMaxima.keys.sorted() {
        metrics.set(
          prefix + "temperature_group_max_celsius",
          groupMaxima[group]!,
          labels: [.init("group", group)]
        )
      }
    }
    return metrics
  }

  private static func updateMaximum(_ maxima: inout [String: Double], group: String, value: Double) {
    maxima[group] = max(maxima[group] ?? value, value)
  }

  private static func registerMetrics(_ metrics: inout MetricRegistry) {
    metrics.register(
      prefix + "thermal_warning_level",
      help: "Darwin thermal warning level from pmset -g therm."
    )
    metrics.register(
      prefix + "performance_warning_level",
      help: "Darwin performance warning level from pmset -g therm."
    )
    metrics.register(
      prefix + "cpu_power_status",
      help: "Darwin CPU power status from pmset -g therm."
    )
    metrics.register(
      prefix + "powermetrics_collect_success",
      help: "Whether the last root powermetrics collection succeeded."
    )
    metrics.register(
      prefix + "ismc_collect_success",
      help: "Whether the last iSMC temperature collection succeeded."
    )
    metrics.register(
      prefix + "powermetrics_sample_timestamp_seconds",
      help: "Unix timestamp of the latest Darwin thermal sample."
    )
    metrics.register(
      prefix + "power_watts",
      help: "Darwin power usage by hardware domain."
    )
    metrics.register(
      prefix + "temperature_celsius",
      help: "Darwin temperature sensor reading collected via iSMC."
    )
    metrics.register(
      prefix + "temperature_group_max_celsius",
      help: "Maximum Darwin temperature by derived sensor group."
    )
    metrics.register(
      prefix + "temperature_max_celsius",
      help: "Maximum Darwin temperature across all iSMC sensors."
    )
  }
}
