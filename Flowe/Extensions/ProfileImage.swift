import UIKit

/// Normalises a picked photo before it is stored or published.
///
/// Profile photos ride along in every catalog fetch as `CKAsset`s, so an untouched 12-megapixel
/// camera roll image would make the student feed expensive to load for everyone. Downscaling to a
/// display-sized square and re-encoding as JPEG keeps a listing's photo in the tens of kilobytes.
enum ProfileImage {
    /// Longest edge of the stored image. Twice the largest avatar drawn (88pt) leaves room for
    /// @3x screens without paying for a full-resolution original.
    static let maxDimension: CGFloat = 600
    static let compressionQuality: CGFloat = 0.8

    /// Longest edge of a stored document scan. Larger than `maxDimension` because a certificate is
    /// read, not glanced at: the issuing school and the year have to survive the downscale.
    static let documentMaxDimension: CGFloat = 1400

    /// Downscale, square-crop and JPEG-encode. Returns nil if the data isn't a decodable image.
    static func prepare(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return squareCropped(image).jpegData(compressionQuality: compressionQuality)
    }

    /// Downscale and JPEG-encode a document photo, keeping its aspect ratio.
    ///
    /// Deliberately not `prepare`: an avatar is always drawn in a circle, so centre-cropping to a
    /// square loses nothing. A certificate is a landscape or portrait sheet of paper, and the same
    /// crop would slice off exactly the parts that make it evidence — the awarding body across the
    /// top, the date and signature along the bottom.
    static func prepareDocument(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return downscaled(image, maxEdge: documentMaxDimension).jpegData(compressionQuality: compressionQuality)
    }

    /// Scale down so the longest edge is at most `maxEdge`, leaving smaller images untouched.
    private static func downscaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let size = CGSize(width: (image.size.width * scale).rounded(),
                          height: (image.size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // the pixel dimensions above are already final
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Centre-crop to a square, then scale down to `maxDimension` if larger.
    private static func squareCropped(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let target = min(side, maxDimension)
        let size = CGSize(width: target, height: target)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // the pixel dimensions above are already final
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            // Draw the full image scaled so its short edge fills the square, centred on the long one.
            let scale = target / side
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (target - drawn.width) / 2,
                y: (target - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
        }
    }
}
