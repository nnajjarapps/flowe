import SwiftUI
import UIKit

/// Profile imagery, from whichever source a listing has.
///
/// An uploaded `photo` always wins; `id` is the Unsplash fallback that seeded reference listings
/// carry. With neither, the soft pink gradient stands in — which is also the loading and failure
/// state, so an avatar never flashes empty.
struct RemoteImage: View {
    let id: String
    var photo: Data?
    var width: Int = 200
    var height: Int = 200

    var body: some View {
        if let photo, let image = UIImage(data: photo) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if id.isEmpty {
            FlowGradients.grad
        } else {
            AsyncImage(url: UnsplashImage.url(id, w: width, h: height)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    FlowGradients.grad
                }
            }
        }
    }
}

/// Circular avatar with an optional gradient story-ring.
struct AvatarView: View {
    let id: String
    var photo: Data?
    var size: CGFloat = 40
    var ring: Bool = false

    var body: some View {
        Group {
            if ring {
                image
                    .overlay(Circle().stroke(Color.flowWhite, lineWidth: 2))
                    .padding(2.5)
                    .background(FlowGradients.gradDark)
                    .clipShape(Circle())
            } else {
                image
            }
        }
    }

    private var image: some View {
        RemoteImage(id: id, photo: photo, width: Int(size * 2), height: Int(size * 2))
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

/// Avatar with a person glyph when there is nothing to show — for the signed-in instructor's own
/// profile, where an empty circle reads as broken rather than as "not set yet".
struct EditableAvatarView: View {
    let id: String
    var photo: Data?
    var size: CGFloat = 88

    private var isEmpty: Bool { photo == nil && id.isEmpty }

    var body: some View {
        ZStack {
            AvatarView(id: id, photo: photo, size: size, ring: true)
            if isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}
