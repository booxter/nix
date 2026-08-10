import Foundation
import LaunchdExporter

enum CLIError: Error, CustomStringConvertible {
  case usage
  case missingValue(String)
  case unknownArgument(String)

  var description: String {
    switch self {
    case .usage:
      return "usage: observability-launchd-export --config PATH --output PATH"
    case let .missingValue(argument):
      return "\(argument) requires a value"
    case let .unknownArgument(argument):
      return "unknown argument: \(argument)"
    }
  }
}

func parse(_ arguments: [String]) throws -> (configuration: URL, output: URL) {
  var configuration: URL?
  var output: URL?
  var index = 0
  while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--config", "--output":
      index += 1
      guard index < arguments.count else { throw CLIError.missingValue(argument) }
      let url = URL(fileURLWithPath: arguments[index])
      if argument == "--config" { configuration = url } else { output = url }
    case "-h", "--help":
      throw CLIError.usage
    default:
      throw CLIError.unknownArgument(argument)
    }
    index += 1
  }
  guard let configuration, let output else { throw CLIError.usage }
  return (configuration, output)
}

do {
  let arguments = try parse(Array(CommandLine.arguments.dropFirst()))
  try LaunchdExportService(
    configurationURL: arguments.configuration,
    outputURL: arguments.output
  ).run()
} catch {
  FileHandle.standardError.write(Data("observability-launchd-export: \(error)\n".utf8))
  exit(1)
}
