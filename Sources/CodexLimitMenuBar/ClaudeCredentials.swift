import CryptoKit
import Foundation
import LocalAuthentication
import Security

// Credentials are intentionally not Codable and are never written by this app.
struct ClaudeCredentials: Sendable {
  let accessToken: String
  let expiresAt: Date?
  let planType: String?
}

protocol ClaudeCredentialReading: Sendable {
  func read(allowInteraction: Bool) throws -> ClaudeCredentials
}

struct ClaudeCredentialReader: ClaudeCredentialReading {
  private let configDirectory: URL
  private let service: String
  private let account: String

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    let customDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    configDirectory = customDirectory.map {
      URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL
    } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    service = Self.keychainService(configDirectory: configDirectory, isCustom: customDirectory != nil)
    let user = environment["USER"] ?? NSUserName()
    account = user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
      ? user : "claude-code-user"
  }

  static func keychainService(configDirectory: URL, isCustom: Bool) -> String {
    guard isCustom else { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(configDirectory.path.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-\(hash.prefix(8))"
  }

  func read(allowInteraction: Bool = false) throws -> ClaudeCredentials {
    let context = LAContext()
    context.interactionNotAllowed = !allowInteraction
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
      return try Self.decode(data)
    }

    // Claude Code itself uses this file when Keychain storage is unavailable.
    let fileURL = configDirectory.appendingPathComponent(".credentials.json")
    if let data = try? Data(contentsOf: fileURL) {
      return try Self.decode(data)
    }
    if status == errSecInteractionNotAllowed || status == errSecAuthFailed
      || status == errSecUserCanceled
    {
      throw ClaudeUsageClientError.keychainAccessDenied
    }
    throw ClaudeUsageClientError.credentialsNotFound
  }

  static func decode(_ data: Data) throws -> ClaudeCredentials {
    // Decode only the fields we need; refresh tokens never leave Claude Code.
    struct Envelope: Decodable {
      struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
        let subscriptionType: String?
      }
      let claudeAiOauth: OAuth?
    }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      let oauth = envelope.claudeAiOauth, !oauth.accessToken.isEmpty,
      oauth.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw ClaudeUsageClientError.invalidCredentials
    }
    return ClaudeCredentials(
      accessToken: oauth.accessToken,
      expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1_000) },
      planType: oauth.subscriptionType
    )
  }
}
