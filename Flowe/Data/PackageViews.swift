import SwiftUI

// Class-package SCREENS (instructor vertical). Co-located with PackageService rather than in a Features/
// subfolder because xcodegen is not installed — a new file in a Features group means fragile pbxproj
// group-path surgery; registering next to its data source (the Data group) is the low-risk path. The
// reusable components (CreditRing, PackageOfferingCard, PackagePurchaseRequestCard …) live in
// FloweCommon.swift. See ClassPackages.md.

// MARK: - Instructor: compose / edit a package offering

/// Create or edit one package offering ("10-class pack · ₪800 · 90-day validity"). Same `Form` idiom as
/// ComposeLessonTypeSheet; maps to `MockDataStore.saveOffering`. No money moves — the footer says so.
struct ComposePackageOfferingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings

    private let editing: RemoteOffering?

    @State private var title: String
    @State private var credits: Int
    @State private var priceText: String
    @State private var neverExpires: Bool
    @State private var validityDays: Int
    @State private var saving = false
    @State private var filterMessage: String?

    private let validityPresets = [30, 60, 90, 180, 365]

    init(editing: RemoteOffering? = nil) {
        self.editing = editing
        _title = State(initialValue: editing?.title ?? "")
        _credits = State(initialValue: editing?.credits ?? 10)
        _priceText = State(initialValue: (editing?.price).flatMap { $0 > 0 ? String($0) : nil } ?? "")
        _neverExpires = State(initialValue: editing?.validityDays == nil)
        _validityDays = State(initialValue: editing?.validityDays ?? 90)
    }

    private var priceValue: Int { Self.wholeNumber(priceText) ?? 0 }
    private var perClass: Int { credits > 0 ? priceValue / credits : priceValue }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. 10-class pack", text: $title).font(FloweFont.sans(14))
                } header: {
                    Text("Package name")
                } footer: {
                    Text("Your words, shown to students exactly as you type them.")
                }

                Section {
                    Stepper(value: $credits, in: 1...100) {
                        Text("^[\(credits) class](inflect: true)").font(FloweFont.sans(14))
                    }
                } header: {
                    Text("Classes included")
                }

                Section {
                    HStack(spacing: 4) {
                        Text(verbatim: settings.currencySymbol)
                            .font(FloweFont.serif(18, .medium)).foregroundStyle(Color.floweInk)
                        TextField("800", text: $priceText)
                            .font(FloweFont.serif(18, .medium)).foregroundStyle(Color.floweInk)
                            .keyboardType(.numberPad)
                    }
                    if priceValue > 0 && credits > 0 {
                        Text("\(settings.money(perClass)) per class")
                            .font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted)
                    }
                } header: {
                    Text("Price")
                } footer: {
                    Text("Flowe takes no payment — students pay you directly (cash or Bit), and you approve each purchase.")
                }

                Section {
                    Toggle("Never expires", isOn: $neverExpires)
                        .font(FloweFont.sans(14)).tint(Color.flowePinkDeep)
                    if !neverExpires {
                        Picker("Valid for", selection: $validityDays) {
                            ForEach(validityPresets, id: \.self) { Text("\($0) days").tag($0) }
                        }
                        .font(FloweFont.sans(14))
                    }
                } header: {
                    Text("Validity")
                } footer: {
                    Text(neverExpires
                         ? "Credits never expire."
                         : "Credits expire \(validityDays) days after you approve the purchase.")
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle(editing == nil ? "New package" : "Edit package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Create" : "Save") { save() }
                        .disabled(!canSave || saving)
                }
            }
            .floweMessage(
                isPresented: .init(get: { filterMessage != nil },
                                   set: { if !$0 { filterMessage = nil } }),
                title: "Check your package",
                detail: filterMessage
            ) { filterMessage = nil }
        }
    }

    private func save() {
        if let rejection = ContentFilter.reject(fields: [title]) { filterMessage = rejection.message; return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let validity = neverExpires ? nil : validityDays
        saving = true
        Task {
            _ = await data.saveOffering(id: editing?.id, title: trimmed, credits: credits, price: priceValue, validityDays: validity)
            dismiss()
        }
    }

    /// Whole-number parse tolerant of Eastern-Arabic-Indic digits (Arabic keyboard) — mirrors
    /// ComposeLessonTypeSheet.wholeNumber so a non-ASCII amount isn't silently dropped.
    private static func wholeNumber(_ text: String) -> Int? {
        var digits = ""
        for ch in text where ch.isNumber {
            guard let v = ch.wholeNumberValue, (0...9).contains(v) else { continue }
            digits.append(Character("\(v)"))
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}

// MARK: - Instructor: package manager (menu + entry to the approval inbox)

struct PackagesManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    @State private var composing = false
    @State private var editing: RemoteOffering?

    private var pendingCount: Int { data.pendingPurchaseCards.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FlowSpacing.lg) {
                    NavigationLink { PackageRequestsView() } label: { requestsRow }
                        .flowePressable()

                    if data.myOfferings.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(data.myOfferings.enumerated()), id: \.element.id) { i, offering in
                            PackageOfferingCard(offering: offering, footer: AnyView(footer(offering)))
                                .opacity(offering.active ? 1 : 0.55)
                                .floweAppear(i)
                        }
                    }
                }
                .padding(FlowSpacing.lg)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Packages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                        .tint(Color.flowePinkDeep)
                }
            }
            .task { await data.syncOfferings() }
            .refreshable { await data.syncOfferings() }
            .sheet(isPresented: $composing) { ComposePackageOfferingSheet() }
            .sheet(item: $editing) { ComposePackageOfferingSheet(editing: $0) }
        }
    }

    private var requestsRow: some View {
        HStack(spacing: FlowSpacing.md) {
            Image(systemName: "tray.full.fill").font(.system(size: 20)).foregroundStyle(Color.flowePinkDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("Purchase requests").font(FloweFont.serif(16)).foregroundStyle(Color.floweInk)
                Text(pendingCount == 0
                     ? "No pending requests"
                     : "^[\(pendingCount) request](inflect: true) waiting for approval")
                    .font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted)
            }
            Spacer()
            if pendingCount > 0 {
                Text(verbatim: "\(pendingCount)")
                    .font(FloweFont.mono(12)).foregroundStyle(.white)
                    .frame(minWidth: 20).padding(5).background(Color.flowePinkDeep).clipShape(Capsule())
            }
            Image(systemName: "chevron.right").foregroundStyle(Color.floweMuted)
        }
        .padding(FlowSpacing.lg)
        .floweCard(cornerRadius: 18)
    }

    private func footer(_ o: RemoteOffering) -> some View {
        HStack(spacing: FlowSpacing.md) {
            if !o.active {
                Text("Archived").font(FloweFont.mono(10)).foregroundStyle(Color.floweMuted)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.floweMuted.opacity(0.10)).clipShape(Capsule())
            }
            Spacer()
            Button("Edit") { editing = o }
                .font(FloweFont.sans(12, .medium)).foregroundStyle(Color.flowePinkDeep)
            Button(o.active ? "Archive" : "Reactivate") {
                Task { await data.setOfferingActive(o, active: !o.active) }
            }
            .font(FloweFont.sans(12, .medium)).foregroundStyle(Color.floweMuted)
        }
        .buttonStyle(.plain)
        .padding(.top, FlowSpacing.xs)
    }

    private var emptyState: some View {
        VStack(spacing: FlowSpacing.sm) {
            Image(systemName: "ticket").font(.system(size: 40)).foregroundStyle(Color.flowePinkSoft)
            Text("No packages yet").font(FloweFont.serif(18)).foregroundStyle(Color.floweInk)
            Text("Sell a prepaid pack — students commit, show up more, and renew. Tap + to create one.")
                .font(FloweFont.sans(13)).foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.top, FlowSpacing.xxxl)
        .padding(.horizontal, FlowSpacing.lg)
    }
}

// MARK: - Instructor: purchase-request approval inbox

struct PackageRequestsView: View {
    @Environment(MockDataStore.self) private var data
    @State private var showingHistory = false

    private var pending: [RemotePurchase] { data.incomingPurchases.filter { $0.status == .pending } }
    private var history: [RemotePurchase] { data.incomingPurchases.filter { $0.status != .pending } }

    var body: some View {
        ScrollView {
            VStack(spacing: FlowSpacing.lg) {
                Picker("", selection: $showingHistory) {
                    Text("Pending").tag(false)
                    Text("History").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, FlowSpacing.lg)

                let rows = showingHistory ? history : pending
                if rows.isEmpty {
                    VStack(spacing: FlowSpacing.sm) {
                        Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(Color.flowePinkSoft)
                        Text(showingHistory ? "No past requests" : "No pending requests")
                            .font(FloweFont.sans(14)).foregroundStyle(Color.floweMuted)
                    }
                    .padding(.top, FlowSpacing.xxxl)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, purchase in
                        PackagePurchaseRequestCard(
                            purchase: purchase,
                            studentPhoto: data.studentPhoto(forOwnerID: purchase.studentID),
                            resolvedName: data.displayIdentity(ownerID: purchase.studentID,
                                                              fallbackName: purchase.studentName).name,
                            onApprove: { Task { await data.decidePurchase(purchase, approved: true) } },
                            onDecline: { Task { await data.decidePurchase(purchase, approved: false) } }
                        )
                        .padding(.horizontal, FlowSpacing.lg)
                        .floweAppear(i)
                    }
                }
            }
            .padding(.vertical, FlowSpacing.lg)
        }
        .background(Color.flowWhite.ignoresSafeArea())
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .task { await data.syncOfferings() }
        .refreshable { await data.syncOfferings() }
    }
}

// MARK: - Student: request to buy a package

/// The student's "buy" sheet — a read-only offering summary + the offline-payment explainer, then a
/// single "Send request" that files the request the instructor approves. No money moves in-app.
struct RequestToBuySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    let offering: RemoteOffering
    var instructorName: String = ""

    @State private var sending = false
    @State private var result: PurchaseRequestResult?

    private var them: String { instructorName.isEmpty ? String(localized: "your instructor") : instructorName }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FlowSpacing.lg) {
                    PackageOfferingCard(offering: offering)

                    VStack(alignment: .leading, spacing: FlowSpacing.sm) {
                        Label("Payment happens in person", systemImage: "hand.wave.fill")
                            .font(FloweFont.sans(14, .medium)).foregroundStyle(Color.floweInk)
                        Text("Flowe never takes payment. \(them) confirms once you've paid them directly (cash or Bit) — then your ^[\(offering.credits) class](inflect: true) are added to your balance.")
                            .font(FloweFont.sans(13)).foregroundStyle(Color.floweMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FlowSpacing.lg)
                    .background(Color.flowePink.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    if let result { resultBanner(result) }
                }
                .padding(FlowSpacing.lg)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Buy package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.tint(Color.floweMuted) }
            }
            .safeAreaInset(edge: .bottom) {
                if result != .requested {
                    GradientButton(title: "Send request", isLoading: sending) { send() }
                        .padding(FlowSpacing.lg)
                        .background(.ultraThinMaterial)
                }
            }
        }
    }

    @ViewBuilder private func resultBanner(_ r: PurchaseRequestResult) -> some View {
        let (icon, tint, msg): (String, Color, LocalizedStringKey) = {
            switch r {
            case .requested: return ("checkmark.circle.fill", .floweSuccess, "Request sent — \(them) will confirm after payment.")
            case .duplicate: return ("clock", .floweMuted, "You already have a request pending with \(them).")
            case .failed:    return ("exclamationmark.triangle", .floweCancel, "Couldn't send — check your connection and try again.")
            }
        }()
        Label(msg, systemImage: icon)
            .font(FloweFont.sans(13, .medium)).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(FlowSpacing.md)
            .floweCard()
    }

    private func send() {
        sending = true
        Task {
            let r = await data.requestPackage(offeringID: offering.id)
            sending = false
            result = r
            if r == .requested { Haptic.success() }
        }
    }
}

// MARK: - Student: credit detail (tapped from the wallet carousel)

struct CreditDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let balance: InstructorBalance
    var instructorName: String = ""
    var instructorPhoto: Data? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: FlowSpacing.xl) {
                CreditRing(remaining: balance.balance, total: max(balance.balance, 1), size: 132, style: .hero)
                    .padding(.top, FlowSpacing.xxl)
                VStack(spacing: FlowSpacing.xs) {
                    Text(verbatim: instructorName.isEmpty ? String(localized: "Your credits") : instructorName)
                        .font(FloweFont.serif(20, .medium)).foregroundStyle(Color.floweInk)
                    Text(expiryText).font(FloweFont.sans(13)).foregroundStyle(Color.floweMuted)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.tint(Color.floweMuted) }
            }
        }
        .presentationDetents([.medium])
    }

    private var expiryText: LocalizedStringKey {
        guard let exp = balance.nextExpiry else { return "Never expires" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0
        return days <= 0 ? "Expires today" : "Expires in ^[\(days) day](inflect: true)"
    }
}
