import Foundation

enum PackedAlphaSource {
  static func resolve(_ args: [String: Any], assetURL: (String) -> URL?) throws -> URL {
    let asset = args["asset"] as? String
    let source = args["sourceUri"] as? String
    guard args["asset"] == nil || args["asset"] is NSNull || asset != nil,
      args["sourceUri"] == nil || args["sourceUri"] is NSNull || source != nil
    else { throw invalid() }
    guard (asset != nil) != (source != nil) else { throw invalid() }
    if let source = source { return try validate(source) }
    guard let asset = asset, !asset.isEmpty, let url = assetURL(asset) else { throw invalid() }
    return url
  }

  // Validate before URL standardization can erase dot segments. Keep the same
  // file/http/https boundary as validatePackedAlphaSourceUri in Dart.
  static func validate(_ value: String) throws -> URL {
    guard let parts = URLComponents(string: value),
      let scheme = parts.scheme, ["file", "http", "https"].contains(scheme),
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.path.hasPrefix("/"), parts.path.lowercased().hasSuffix(".mp4"),
      !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      let url = parts.url
    else { throw invalid() }
    if scheme == "file" {
      var directory: ObjCBool = false
      guard (parts.host ?? "").isEmpty,
        FileManager.default.fileExists(atPath: parts.path, isDirectory: &directory),
        !directory.boolValue
      else { throw invalid() }
    } else if (parts.host ?? "").isEmpty {
      throw invalid()
    }
    return url
  }

  private static func invalid() -> NSError {
    NSError(domain: "packed_alpha", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Expected one bundled asset or trusted absolute packed MP4 URI"])
  }
}
