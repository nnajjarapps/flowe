import SwiftUI

struct BookingSheet: View {
    let instructor: Instructor
    let onClose: () -> Void

    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings

    @State private var step = 0
    @State private var day = ""
    @State private var time = ""
    @State private var type = ""
    @State private var booked = false
    @State private var showReport = false
    @State private var confirmBlock = false

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch step {
                    case 0: stepIntro
                    case 1: stepDay
                    case 2: stepTimeType
                    default: stepConfirm
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color.flowWhite)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if type.isEmpty { type = instructor.sessionTypes.first ?? "" }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(
                reportedID: instructor.ownerID ?? "",
                reportedName: instructor.name,
                content: .instructorListing,
                contentID: instructor.ownerID ?? "",
                snapshot: [instructor.name, instructor.city, instructor.cert, instructor.bio ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            )
        }
        .confirmationDialog("Block \(instructor.firstName)?",
                            isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let id = instructor.ownerID {
                    data.block(id: id, name: instructor.name)
                }
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their profile or messages. You can undo this in Settings.")
        }
    }

    // MARK: - Hero band

    private var hero: some View {
        ZStack {
            RemoteImage(id: instructor.img, photo: instructor.photo, width: 600, height: 280)
                .frame(height: 144)
                .clipped()
            FlowGradients.grad.opacity(0.7)
            LinearGradient(
                colors: [Color.black.opacity(0.35), .clear],
                startPoint: .bottom, endPoint: .top
            )

            VStack {
                HStack {
                    Spacer()
                    // A listing's name, city, bio and certification are user-written and public, so
                    // students need a way to flag one (Guideline 1.2).
                    Menu {
                        Button("Report this profile", systemImage: "flag") { showReport = true }
                        Button("Block \(instructor.firstName)", systemImage: "hand.raised",
                               role: .destructive) { confirmBlock = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityIdentifier("booking.moderation")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(instructor.name)
                            .font(FloweFont.serif(17))
                            .foregroundStyle(.white)
                        HStack(spacing: 4) {
                            Image(systemName: "mappin").font(.system(size: 10))
                            Text(instructor.city).font(FloweFont.mono(11))
                        }
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.system(size: 10))
                        Text("\(instructor.rating, specifier: "%.1f") (\(instructor.reviews))")
                            .font(FloweFont.mono(11))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(12)
        }
        .frame(height: 144)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Step 0

    private var stepIntro: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                statCol("\(instructor.students)", "Students")
                statCol("\(instructor.yearsExp)yrs", "Exp.")
                statCol("\(instructor.reviews)", "Reviews")
            }
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.floweBorder).frame(height: 1)
            }
            .padding(.bottom, 16)

            Text(instructor.bio ?? "Certified Pilates instructor.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweInk)
                .lineSpacing(4)
                .padding(.bottom, 16)

            FlowLayout(spacing: 6) {
                ForEach(instructor.specialties, id: \.self) { s in
                    Text(s)
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.flowePinkDeep)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.flowePink.opacity(0.12), in: Capsule())
                }
            }
            .padding(.bottom, 20)

            GradientButton(title: "Book a Session · \(settings.money(instructor.price))") { step = 1 }
        }
    }

    private func statCol(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(FloweFont.serif(18, .medium))
                .foregroundStyle(Color.floweInk)
            Text(label)
                .font(FloweFont.mono(9))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 1

    private var stepDay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                backButton { step = 0 }
                Text("Choose a day")
                    .font(FloweFont.serif(17))
                    .foregroundStyle(Color.floweInk)
            }
            .padding(.bottom, 12)

            Text("Available: \(instructor.available.joined(separator: ", "))")
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)
                .padding(.bottom, 12)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(FloweConstants.days, id: \.self) { d in
                    let short = String(d.prefix(3))
                    let rest = String(d.dropFirst(4))
                    let avail = instructor.available.contains(short)
                    let sel = day == d
                    Button { if avail { day = d } } label: {
                        VStack(spacing: 2) {
                            Text(short)
                                .font(FloweFont.mono(10))
                                .foregroundStyle(sel ? .white : Color.floweInk)
                            Text(rest)
                                .font(FloweFont.sans(11))
                                .foregroundStyle(sel ? .white : Color.floweInk)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if sel {
                                RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark)
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(avail ? Color.floweCardBg : Color.floweBorder.opacity(0.25))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))
                            }
                        }
                        .opacity(avail ? 1 : 0.35)
                    }
                    .disabled(!avail)
                }
            }
            .padding(.bottom, 20)

            GradientButton(title: "Continue", enabled: !day.isEmpty) { step = 2 }
        }
    }

    // MARK: - Step 2

    private var stepTimeType: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                backButton { step = 1 }
                Text("Time & type")
                    .font(FloweFont.serif(17))
                    .foregroundStyle(Color.floweInk)
            }
            .padding(.bottom, 4)

            Text(day)
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)
                .padding(.bottom, 12)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(FloweConstants.times, id: \.self) { t in
                    let sel = time == t
                    Button { time = t } label: {
                        Text(t)
                            .font(FloweFont.mono(11))
                            .foregroundStyle(sel ? .white : Color.floweInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background {
                                if sel {
                                    RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark)
                                } else {
                                    RoundedRectangle(cornerRadius: 12).fill(Color.floweCardBg)
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))
                                }
                            }
                    }
                }
            }
            .padding(.bottom, 16)

            Text("SESSION TYPE")
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                ForEach(instructor.sessionTypes, id: \.self) { t in
                    let sel = type == t
                    Button { type = t } label: {
                        HStack(spacing: 6) {
                            Image(systemName: typeIcon(t)).font(.system(size: 12))
                            Text(t).font(FloweFont.sans(12))
                        }
                        .foregroundStyle(sel ? .white : Color.floweMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if sel {
                                RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark)
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(Color.floweCardBg)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 20)

            GradientButton(title: "Request · \(settings.money(instructor.price))", enabled: !time.isEmpty) {
                confirmBooking()
                step = 3
            }
        }
    }

    /// Persist the booking exactly once when the user confirms.
    private func confirmBooking() {
        guard !booked else { return }
        data.addBooking(instructor: instructor, day: day, time: time, type: type)
        booked = true
    }

    private func typeIcon(_ t: String) -> String {
        switch t {
        case "Online": return "video.fill"
        case "Private": return "person.crop.circle.badge.checkmark"
        default: return "person.2.fill"
        }
    }

    // MARK: - Step 3

    private var stepConfirm: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(FlowGradients.gradDark, in: Circle())
                .padding(.top, 16)
                .padding(.bottom, 16)

            Text("Request sent!")
                .font(FloweFont.serif(22))
                .foregroundStyle(Color.floweInk)
                .padding(.bottom, 4)

            Text("\(instructor.name) · \(type)")
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweInk)
                .padding(.bottom, 4)

            Text("\(day) at \(time)")
                .font(FloweFont.mono(12))
                .foregroundStyle(Color.floweMuted)
                .padding(.bottom, 12)

            Text("\(instructor.firstName) will confirm your session shortly. You'll see it update in Bookings.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

            // Flowe takes no payment for sessions in this release — the student settles up with
            // the instructor directly, so no service fee or total is shown.
            VStack(spacing: 0) {
                receiptRow("Session fee", settings.money(instructor.price), bold: true)
                    .padding(.top, 4)
                Text("Paid directly to your instructor")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .padding(16)
            .floweCard()
            .padding(.bottom, 20)

            GradientButton(title: "Done") { onClose() }
        }
        .frame(maxWidth: .infinity)
    }

    private func receiptRow(_ label: String, _ value: String, bold: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(bold ? Color.floweInk : Color.floweMuted)
            Spacer()
            Text(value)
                .foregroundStyle(Color.floweInk)
        }
        .font(FloweFont.sans(13, bold ? .medium : .regular))
    }

    // MARK: - Helpers

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.floweInk)
        }
    }
}

#Preview {
    BookingSheet(instructor: MockDataStore.preview.instructors[0], onClose: {})
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
