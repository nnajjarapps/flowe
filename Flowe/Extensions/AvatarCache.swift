import UIKit
import Intents
import CryptoKit

/// Sender-avatar hand-off from the app to the Notification Service Extension.
///
/// The DM push carries no image (ChatMessage has no photo field; the photo is a CKAsset on a
/// different record). So the app pre-caches each conversation counterpart's prepared avatar JPEG
/// into the shared App Group container, keyed by the counterpart's ownerID, and the extension reads
/// it locally — zero network, zero decryption.
enum AvatarCache {

    static let appGroup = "group.com.flowepilates.app"

    private static var directory: URL? {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("SenderAvatars", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// SHA256 of the ownerID → filesystem-safe, collision-free (Apple ids and conversation ids
    /// contain dots/tildes). CryptoKit is already a project dependency (DM crypto).
    private static func fileURL(senderID: String) -> URL? {
        guard let dir = directory else { return nil }
        let key = SHA256.hash(data: Data(senderID.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(key + ".jpg")
    }

    // MARK: - App side (write)

    /// Cache a counterpart's avatar. `photo` is the already-prepared ProfileImage JPEG bytes.
    /// Re-squares + shrinks to a notification-thumbnail size (240px) so the file stays tiny.
    static func write(senderID: String, photo: Data) {
        guard let url = fileURL(senderID: senderID), let img = UIImage(data: photo) else { return }
        let side: CGFloat = 240
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            let s = side / min(img.size.width, img.size.height)
            let d = CGSize(width: img.size.width * s, height: img.size.height * s)
            img.draw(in: CGRect(x: (side - d.width) / 2, y: (side - d.height) / 2, width: d.width, height: d.height))
        }
        try? square.jpegData(compressionQuality: 0.7)?.write(to: url, options: .atomic)
    }

    // MARK: - Blocked senders (app writes, the extension reads)
    //
    // A CKQuerySubscription push is CloudKit's and can't be filtered server-side, so a blocked user's DM
    // still pushes to the blocker. The extension is the only interception point — it reads this shared
    // list so it never reveals a blocked sender's message.

    private static let blockedKey = "flowe.blockedSenderIDs"
    private static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// App side: mirror the current block list into the App Group whenever it changes.
    static func writeBlocked(_ ids: [String]) {
        sharedDefaults?.set(ids, forKey: blockedKey)
    }

    // MARK: - Account deletion

    /// Erase all App-Group residue on account deletion: every cached counterpart face photo AND the
    /// mirrored block list. The deletion path otherwise leaves other people's avatars on disk and the
    /// block list in shared defaults — surviving "delete everything" and leaking to the next account
    /// on a shared device (avatars are keyed by the OTHER party's ownerID, so a new session never
    /// overwrites them).
    static func purgeAll() {
        if let dir = directory { try? FileManager.default.removeItem(at: dir) }
        sharedDefaults?.removeObject(forKey: blockedKey)
    }

    /// Extension side: has the recipient blocked this sender? Then hide their notification's content.
    static func isBlockedSender(_ senderID: String) -> Bool {
        sharedDefaults?.stringArray(forKey: blockedKey)?.contains(senderID) ?? false
    }

    // MARK: - Extension side (read)

    static func image(senderID: String) -> INImage? {
        guard let url = fileURL(senderID: senderID),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return INImage(imageData: data)
    }

    /// Brand-gradient monogram, parity with the app's avatar placeholder (FlowGradients.grad:
    /// E8789A → F4A8C0 → FFC2D4) with a white initial. Requires Intents (INImage) + UIKit.
    static func monogram(name: String, size: CGFloat = 240) -> INImage {
        let initial = String(name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?")
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: fmt).image { ctx in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            ctx.cgContext.addEllipse(in: rect)
            ctx.cgContext.clip()
            // FlowGradients.grad
            let colors = [UIColor(red: 0.9098, green: 0.4706, blue: 0.6039, alpha: 1).cgColor,  // E8789A
                          UIColor(red: 0.9569, green: 0.6588, blue: 0.7529, alpha: 1).cgColor,  // F4A8C0
                          UIColor(red: 1.0,    green: 0.7608, blue: 0.8314, alpha: 1).cgColor]  // FFC2D4
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 0.5, 1]) {
                ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                                 end: CGPoint(x: size, y: size), options: [])
            }
            let para = NSMutableParagraphStyle(); para.alignment = .center
            // Bundled serif for parity; systemFont if the NSE couldn't register the font.
            let font = UIFont(name: "Fraunces-Medium", size: size * 0.4)
                ?? .systemFont(ofSize: size * 0.4, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            let s = initial as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: (size - sz.width) / 2, y: (size - sz.height) / 2), withAttributes: attrs)
        }
        return INImage(imageData: img.jpegData(compressionQuality: 0.9) ?? Data())
    }
}
