import Foundation

public protocol SketchyBarRunning {
  func run(_ arguments: [String]) throws
}

public struct SketchyBarError: Error, CustomStringConvertible {
  public let status: Int32

  public var description: String {
    "SketchyBar exited with status \(status)"
  }
}

public final class ProcessSketchyBarRunner: SketchyBarRunning {
  private let executable: URL

  public init(executable: URL) {
    self.executable = executable
  }

  public func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw SketchyBarError(status: process.terminationStatus)
    }
  }
}
