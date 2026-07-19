import SwiftUI

/// AsyncImage wrapper that shows a soft pink gradient placeholder while loading / on failure.
struct RemoteImage: View {
    let id: String
    var width: Int = 200
    var height: Int = 200

    var body: some View {
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

/// Circular avatar with an optional gradient story-ring.
struct AvatarView: View {
    let id: String
    var size: CGFloat = 40
    var ring: Bool = false

    var body: some View {
        Group {
            if ring {
                RemoteImage(id: id, width: Int(size * 2), height: Int(size * 2))
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.flowWhite, lineWidth: 2))
                    .padding(2.5)
                    .background(FlowGradients.gradDark)
                    .clipShape(Circle())
            } else {
                RemoteImage(id: id, width: Int(size * 2), height: Int(size * 2))
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
    }
}
