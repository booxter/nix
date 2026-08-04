import Foundation
import ThermalExporter

enum CLIError: Error, CustomStringConvertible {
  case usage
  case missingISMC
  case unknownArgument(String)

  var description: String {
    switch self {
    case .usage:
      return "usage: observability-thermal-export --ismc PATH"
    case .missingISMC:
      return "--ismc is required"
    case let .unknownArgument(argument):
      return "unknown argument: \(argument)"
    }
  }
}

func parse(_ arguments: [String]) throws -> String {
  var ismc: String?
  var index = 0
  while index < arguments.count {
    switch arguments[index] {
    case "--ismc":
      index += 1
      guard index < arguments.count else { throw CLIError.missingISMC }
      ismc = arguments[index]
    case "-h", "--help":
      throw CLIError.usage
    default:
      throw CLIError.unknownArgument(arguments[index])
    }
    index += 1
  }
  guard let ismc else { throw CLIError.missingISMC }
  return ismc
}

do {
  let ismc = try parse(Array(CommandLine.arguments.dropFirst()))
  try ThermalExporterService(ismcPath: ismc).run()
} catch {
  FileHandle.standardError.write(Data("observability-thermal-export: \(error)\n".utf8))
  exit(1)
}
