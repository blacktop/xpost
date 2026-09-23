#if canImport(UniformTypeIdentifiers)
  import UniformTypeIdentifiers
#endif

// Fixed for the formats the networks accept, so the type does not depend on LaunchServices,
// which a sandbox may refuse to consult.
private let imageTypesByExtension = [
  "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
  "webp": "image/webp", "heic": "image/heic", "avif": "image/avif",
]

/// The MIME type to declare for an image, from its file extension.
func imageMIMEType(forExtension ext: String) -> String {
  if let known = imageTypesByExtension[ext.lowercased()] {
    return known
  }
  #if canImport(UniformTypeIdentifiers)
    if let system = UTType(filenameExtension: ext)?.preferredMIMEType {
      return system
    }
  #endif
  return "application/octet-stream"
}
