import Foundation

public protocol CacheProbing: AnyObject {
  func check(completion: @escaping (Bool) -> Void)
  func cancel()
}

public protocol ResolverWriting {
  func setEnabled(_ enabled: Bool) throws -> Bool
}

public struct ResolverFile: ResolverWriting {
  private static let marker = "# Managed by home-cache-dns.\n"
  private let url: URL
  private let contents: String

  public init(url: URL, nameserver: String) {
    self.url = url
    contents = Self.marker + "nameserver \(nameserver)\n"
  }

  public func setEnabled(_ enabled: Bool) throws -> Bool {
    let manager = FileManager.default
    let existing: String?
    do {
      existing = try String(contentsOf: url, encoding: .utf8)
    } catch CocoaError.fileReadNoSuchFile {
      existing = nil
    }

    // Refuse to replace an operator's resolver or a nix-darwin static file.
    if let existing, !existing.hasPrefix(Self.marker) {
      throw ResolverError.foreignFile(url.path)
    }

    if enabled {
      guard existing != contents else {
        return false
      }
      try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url, atomically: true, encoding: .utf8)
      return true
    }

    guard existing != nil else {
      return false
    }
    try manager.removeItem(at: url)
    return true
  }
}

enum ResolverError: Error {
  case foreignFile(String)
}

// All callbacks run on the main queue. A new path invalidates any probe still
// completing on the previous network, including a late successful handshake.
public final class ResolverController {
  private let probe: CacheProbing
  private let resolver: ResolverWriting
  private let reportError: (Error) -> Void
  private let reportChange: (Bool) -> Void
  private var generation = 0

  public init(
    probe: CacheProbing,
    resolver: ResolverWriting,
    reportError: @escaping (Error) -> Void,
    reportChange: @escaping (Bool) -> Void = { _ in }
  ) {
    self.probe = probe
    self.resolver = resolver
    self.reportError = reportError
    self.reportChange = reportChange
  }

  public func refresh() {
    generation += 1
    let currentGeneration = generation
    probe.cancel()
    probe.check { [weak self] reachable in
      guard let self, self.generation == currentGeneration else {
        return
      }
      self.apply(reachable)
    }
  }

  public func stop() {
    generation += 1
    probe.cancel()
    apply(false)
  }

  private func apply(_ enabled: Bool) {
    do {
      if try resolver.setEnabled(enabled) {
        reportChange(enabled)
      }
    } catch {
      reportError(error)
    }
  }
}
