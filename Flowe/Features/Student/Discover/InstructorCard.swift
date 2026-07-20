import SwiftUI

/// Horizontal Discover list row: left image + right detail column, tappable.
struct InstructorCard: View {
    @Environment(AppSettings.self) private var settings
    let instructor: Instructor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Left image with gradient overlay
                RemoteImage(id: instructor.img, photo: instructor.photo, width: 160, height: 160)
                    .frame(width: 88)
                    .frame(maxHeight: .infinity)
                    .background(Color.flowePinkPale)
                    .overlay(FlowGradients.grad.opacity(0.35))
                    .clipped()

                // Right detail column
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Text(instructor.name)
                            .font(FloweFont.serif(15))
                            .foregroundStyle(Color.floweInk)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.flowePink)
                            Text(String(format: "%.1f", instructor.rating))
                                .font(FloweFont.mono(11))
                                .foregroundStyle(Color.flowePinkDeep)
                        }
                    }
                    .padding(.bottom, 2)

                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.system(size: 10))
                        Text(instructor.city)
                            .font(FloweFont.sans(11))
                    }
                    .foregroundStyle(Color.floweMuted)
                    .padding(.bottom, 8)

                    HStack(spacing: 4) {
                        ForEach(instructor.specialties.prefix(2), id: \.self) { s in
                            SpecialtyTag(text: s)
                        }
                    }
                    .padding(.bottom, 8)

                    HStack {
                        Text(instructor.sessionTypes.prefix(2).joined(separator: " · "))
                            .font(FloweFont.mono(11))
                            .foregroundStyle(Color.floweMuted)
                        Spacer()
                        Text(settings.money(instructor.price))
                            .font(FloweFont.serif(13, .medium))
                            .foregroundStyle(Color.floweInk)
                    }
                }
                .padding(12)
            }
            .fixedSize(horizontal: false, vertical: true)
            .floweCard()
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let data = MockDataStore.preview
    return VStack(spacing: 12) {
        ForEach(data.instructors.prefix(2)) { ins in
            InstructorCard(instructor: ins) {}
        }
    }
    .padding()
    .background(Color.flowWhite)
    .environment(data)
    .environment(AppSettings())
}
