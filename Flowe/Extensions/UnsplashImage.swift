import Foundation

/// Builds an Unsplash URL from the photo IDs stored in the mock data,
/// mirroring the `images.unsplash.com/photo-<id>?w=&h=&fit=crop` pattern in the Figma mockup.
enum UnsplashImage {
    static func url(_ id: String, w: Int, h: Int) -> URL? {
        URL(string: "https://images.unsplash.com/photo-\(id)?w=\(w)&h=\(h)&fit=crop&auto=format")
    }

    /// Convenience for square avatars.
    static func square(_ id: String, _ side: Int) -> URL? {
        url(id, w: side, h: side)
    }
}
