import Foundation

public struct OCRResult: Codable, Equatable, Sendable {
  public var text: String
  public var detectedURLs: [URL]
  public init(text: String) {
    self.text = text
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
    var seen = Set<URL>()
    detectedURLs = matches.compactMap { m in
      guard let u = m.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
        seen.insert(u).inserted
      else { return nil }
      return u
    }
  }
}
