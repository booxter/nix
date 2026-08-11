import Foundation
import ThermalExporter

enum CLIError: Error, CustomStringConvertible {
  case usage
  case missingISMC
  case unknownArgument(String)

  var description: String {
    switch self {
    case .usage:
      return "usage: observability-thermal-export --ismc PATH --textfile-directory PATH"
    case .missingISMC:
      return "--ismc is required"
    case let .unknownArgument(argument):
      return "unknown argument: \(argument)"
    }
  }
}

struct Options {
  let ismc: String
  let textfileDirectory: String
}

func parse(_ arguments: [String]) throws -> Options {
  var ismc: String?
  var textfileDirectory = "/var/lib/observability-thermal/textfile"
  var index = 0
  while index < arguments.count {
    switch arguments[index] {
    case "--ismc":
      index += 1
      guard index < arguments.count else { throw CLIError.missingISMC }
      ismc = arguments[index]
    case "--textfile-directory":
      index += 1
      guard index < arguments.count else { throw CLIError.usage }
      textfileDirectory = arguments[index]
    case "-h", "--help":
      throw CLIError.usage
    default:
      throw CLIError.unknownArgument(arguments[index])
    }
    index += 1
  }
  guard let ismc else { throw CLIError.missingISMC }
  return Options(ismc: ismc, textfileDirectory: textfileDirectory)
}

do {
  let options = try parse(Array(CommandLine.arguments.dropFirst()))
  try ThermalExporterService(
    ismcPath: options.ismc,
    textfileDirectory: URL(fileURLWithPath: options.textfileDirectory)
  ).run()
} catch {
  FileHandle.standardError.write(Data("observability-thermal-export: \(error)\n".utf8))
  exit(1)
}
