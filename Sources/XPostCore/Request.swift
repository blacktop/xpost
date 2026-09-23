/// The message payload shared across all targets.
public struct Request: Sendable, Equatable {
  public var message: String
  public var link: String
  public var imagePath: String
  public var imageAlt: String

  public init(message: String, link: String = "", imagePath: String = "", imageAlt: String = "") {
    self.message = message
    self.link = link
    self.imagePath = imagePath
    self.imageAlt = imageAlt
  }

  /// The post body: the message, then the optional link after a blank line.
  public var text: String {
    link.isEmpty ? message : message + "\n\n" + link
  }
}
