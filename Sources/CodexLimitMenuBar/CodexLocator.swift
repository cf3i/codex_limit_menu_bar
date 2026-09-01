import Foundation

struct CodexLocator {
  static let userDefaultsKey = "codexExecutablePath"

  private let fileManager: FileManager
  private let environment: [String: String]
  private let userDefaults: UserDefaults

  init(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    userDefaults: UserDefaults = .standard
  ) {
    self.fileManager = fileManager
    self.environment = environment
    self.userDefaults = userDefaults
  }

  func locate() -> URL? {
    for candidate in candidatePaths() where fileManager.isExecutableFile(atPath: candidate) {
      return URL(fileURLWithPath: candidate)
    }
    return nil
  }

  func saveUserSelectedPath(_ path: String) {
    userDefaults.set(path, forKey: Self.userDefaultsKey)
  }

  private func candidatePaths() -> [String] {
    let home = fileManager.homeDirectoryForCurrentUser.path
    var paths: [String] = []

    if let selected = userDefaults.string(forKey: Self.userDefaultsKey), !selected.isEmpty {
      paths.append(selected)
    }

    if let path = environment["PATH"] {
      paths.append(
        contentsOf: path.split(separator: ":").map { directory in
          URL(fileURLWithPath: String(directory))
            .appendingPathComponent("codex")
            .path
        }
      )
    }

    paths.append(contentsOf: [
      "\(home)/.npm-global/bin/codex",
      "\(home)/.local/bin/codex",
      "\(home)/.bun/bin/codex",
      "\(home)/.cargo/bin/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      "/usr/bin/codex",
    ])

    return paths.reduce(into: [String]()) { result, path in
      let expanded = NSString(string: path).expandingTildeInPath
      if !result.contains(expanded) {
        result.append(expanded)
      }
    }
  }
}
