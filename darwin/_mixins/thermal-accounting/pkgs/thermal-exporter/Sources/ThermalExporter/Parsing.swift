import Foundation

public struct ISMCSensor: Decodable, Sendable {
  public let key: String?
  public let type: String?
  public let quantity: Double?
  public let unit: String?
}

public struct TemperatureReading: Equatable, Sendable {
  public let name: String
  public let key: String
  public let type: String
  public let group: String
  public let value: Double
}

public func pmsetLevel(_ key: String, in output: String, fallback: Int = 0) -> Int {
  for line in output.split(whereSeparator: { $0.isNewline }) {
    let text = String(line)
    guard text.range(of: key, options: .caseInsensitive) != nil else { continue }
    if let range = text.range(of: #"\d+"#, options: .regularExpression),
      let level = Int(text[range])
    {
      return level
    }
  }
  return fallback
}

public func powerReadings(in output: String) -> [(domain: String, watts: Double)] {
  output.split(whereSeparator: { $0.isNewline }).compactMap { line in
    let fields = line.split(separator: " ")
    guard fields.count == 4,
      ["CPU", "GPU", "ANE"].contains(String(fields[0])),
      fields[1] == "Power:",
      let value = Double(fields[2]),
      fields[3] == "mW" || fields[3] == "W"
    else {
      return nil
    }
    let watts = fields[3] == "mW" ? value / 1000 : value
    return (String(fields[0]).lowercased(), watts)
  }
}

public func temperatureReadings(from data: Data) throws -> [TemperatureReading] {
  let sensors = try JSONDecoder().decode([String: ISMCSensor].self, from: data)
  return sensors.compactMap { name, sensor in
    guard let quantity = sensor.quantity,
      sensor.unit?.contains("°C") == true,
      (0 ... 150).contains(quantity)
    else {
      return nil
    }
    return TemperatureReading(
      name: name,
      key: sensor.key ?? "",
      type: sensor.type ?? "",
      group: temperatureGroup(name),
      value: quantity
    )
  }.sorted { $0.name < $1.name }
}

public func temperatureGroup(_ name: String) -> String {
  let lower = name.lowercased()
  if lower.hasPrefix("cpu performance core") { return "cpu_perf" }
  if lower.hasPrefix("cpu efficiency core") { return "cpu_eff" }
  if lower.hasPrefix("gpu ") || lower.range(of: #"^gpu\s*\d"#, options: .regularExpression) != nil {
    return "gpu"
  }
  if lower.hasPrefix("nand") || lower.hasPrefix("nvme") { return "storage" }
  if lower.hasPrefix("memory ") { return "memory" }
  if lower.hasPrefix("power supply") { return "power_supply" }
  if lower.range(of: #"^pmu2? "#, options: .regularExpression) != nil { return "pmu" }
  if lower.hasPrefix("battery ") || lower.hasPrefix("gas gauge battery") { return "battery" }
  if lower.hasPrefix("airport ") { return "wireless" }
  if lower.hasPrefix("pcie ") { return "pcie" }
  return "other"
}
