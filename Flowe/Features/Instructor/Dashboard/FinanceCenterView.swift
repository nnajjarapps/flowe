import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Model
//
// The instructor money command centre. Phase A is computed ENTIRELY from data the app already has:
// completed-session prices (`sessionEarning`), No-Show Shield fee state, approved package purchases,
// and the cover-pay ledger. Everything is TRACKED (students settle off-app in cash/Bit) until Flowe
// Pay makes it processed. The two fields that need a backend endpoint — per-student remaining credits
// (`balances`) and `creditLiability` — are stubbed nil/empty here and light up in Phase B.

enum FinancePeriod: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", quarter = "Quarter", year = "Year"
    var id: String { rawValue }

    /// Start of the current window; the window is [start, now].
    func start(_ now: Date, _ cal: Calendar) -> Date {
        switch self {
        case .week:    return cal.date(byAdding: .day, value: -7, to: now) ?? now
        case .month:   return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        case .quarter: return cal.date(byAdding: .month, value: -3, to: now) ?? now
        case .year:    return cal.date(from: cal.dateComponents([.year], from: now)) ?? now
        }
    }
    /// Start of the previous window (the previous window is [prevStart, start]).
    func prevStart(_ now: Date, _ cal: Calendar) -> Date {
        let s = start(now, cal)
        switch self {
        case .week:    return cal.date(byAdding: .day, value: -7, to: s) ?? s
        case .month:   return cal.date(byAdding: .month, value: -1, to: s) ?? s
        case .quarter: return cal.date(byAdding: .month, value: -3, to: s) ?? s
        case .year:    return cal.date(byAdding: .year, value: -1, to: s) ?? s
        }
    }
}

struct FinanceOffering: Identifiable { let id: String; let title: String; let price: Int; let sold: Int; let revenue: Int; let redemptionPct: Int? }
struct FinanceBalance: Identifiable { let id: String; let name: String; let remaining: Int; let total: Int; let value: Int; let expiresInDays: Int? }
struct FinanceClient: Identifiable { let id: String; let name: String; let sessions: Int; let spend: Int }

struct FinanceSummary {
    var trackedRevenue = 0
    var trendPct: Int?
    var collected = 0
    var owedToYou = 0
    var coverPay = 0
    var creditLiability: Int?          // Phase B
    var mixSessions = 0, mixPackages = 0, mixFees = 0, mixCover = 0
    var offerings: [FinanceOffering] = []
    var balances: [FinanceBalance] = []   // Phase B
    var feesOwed = 0, feesCollected = 0, feesWaived = 0
    var topClients: [FinanceClient] = []
    var avgPerSession = 0, avgPerClient = 0, packageAttachPct = 0, noShowRatePct = 0
    var isEmpty: Bool { trackedRevenue == 0 && offerings.isEmpty && topClients.isEmpty }
}

// MARK: - Aggregator (all from existing accessors)

extension MockDataStore {
    func financeSummary(_ period: FinancePeriod, now: Date = Date()) -> FinanceSummary {
        var s = FinanceSummary()
        let cal = Calendar.current
        let start = period.start(now, cal), prevStart = period.prevStart(now, cal)
        func within(_ d: Date?, _ from: Date, _ to: Date) -> Bool { guard let d else { return false }; return d >= from && d < to }

        let bookings = incomingBookings
        let completed = bookings.filter { $0.status == .completed }

        // Sessions (tracked) — priced from the booked lesson type.
        func sessionRevenue(_ from: Date, _ to: Date) -> Int {
            completed.filter { within($0.sessionStart(now: now), from, to) }.reduce(0) { $0 + sessionEarning(for: $1) }
        }
        s.mixSessions = sessionRevenue(start, now)

        // Fees (No-Show Shield) — dated by the session they attach to.
        for b in bookings where within(b.sessionStart(now: now), start, now) {
            switch b.feeStatus {
            case .owed:      s.feesOwed += b.feeAmount
            case .collected: s.feesCollected += b.feeAmount
            case .waived:    s.feesWaived += b.feeAmount
            default: break
            }
        }
        s.mixFees = s.feesCollected

        // Packages — approved purchases in the window; per-offering roll-up.
        let approved = incomingPurchases.filter { $0.status == .approved }
        let approvedInPeriod = approved.filter { within($0.createdAt, start, now) }
        s.mixPackages = approvedInPeriod.reduce(0) { $0 + $1.price }
        s.offerings = myOfferings.map { off in
            let sold = approvedInPeriod.filter { $0.offeringID == off.id }
            return FinanceOffering(id: off.id, title: off.title, price: off.price,
                                   sold: sold.count, revenue: sold.reduce(0) { $0 + $1.price },
                                   redemptionPct: nil)   // Phase B
        }.filter { $0.sold > 0 || myOfferings.count <= 4 }

        // Cover pay ledger.
        s.mixCover = totalCoverOwed
        s.coverPay = totalCoverOwed

        s.mixFees = s.feesCollected
        s.trackedRevenue = s.mixSessions + s.mixPackages + s.mixFees + s.mixCover
        s.collected = s.mixPackages + s.feesCollected
        s.owedToYou = s.feesOwed

        // Phase B — per-student credit balances (from /credits/clients) → liability + the balances list.
        if !studentBalances.isEmpty {
            s.creditLiability = studentBalances.reduce(0) { $0 + $1.value }
            s.balances = studentBalances.map { b in
                let days = b.nextExpiry.map { max(0, cal.dateComponents([.day], from: now, to: $0).day ?? 0) }
                // Resolve the LIVE name — the backend's student_name is the frozen purchase-time
                // snapshot, which reads "Member" for anyone who bought before setting a name.
                let live = displayIdentity(ownerID: b.studentID, fallbackName: b.studentName).name
                return FinanceBalance(id: b.studentID, name: live, remaining: b.remaining,
                                      total: b.granted, value: b.value, expiresInDays: days)
            }
        }

        // Trend vs the previous full period.
        let prevTotal = sessionRevenue(prevStart, start)
            + approved.filter { within($0.createdAt, prevStart, start) }.reduce(0) { $0 + $1.price }
        if prevTotal > 0 { s.trendPct = Int(((Double(s.trackedRevenue) - Double(prevTotal)) / Double(prevTotal) * 100).rounded()) }

        // Top clients — lifetime spend from completed sessions. Names resolve live (booking.studentName
        // is a frozen snapshot that can read "Member"), matching SessionRow/StudentsList/ReviewRow.
        var byClient: [String: (name: String, sessions: Int, spend: Int)] = [:]
        for b in completed {
            guard let id = b.studentID else { continue }
            var e = byClient[id] ?? (b.studentName, 0, 0)
            e.sessions += 1; e.spend += sessionEarning(for: b)
            if e.name.isEmpty { e.name = b.studentName }
            byClient[id] = e
        }
        s.topClients = byClient.map { id, v in
            FinanceClient(id: id, name: displayIdentity(ownerID: id, fallbackName: v.name).name,
                          sessions: v.sessions, spend: v.spend)
        }
        .sorted { $0.spend > $1.spend }.prefix(3).map { $0 }

        // KPIs.
        let completedInPeriod = completed.filter { within($0.sessionStart(now: now), start, now) }
        let noShows = bookings.filter { $0.attendance == .noShow && within($0.sessionStart(now: now), start, now) }.count
        let clientsWithPackage = Set(approved.map { $0.studentID })
        let allClients = Set(bookings.compactMap { $0.studentID })
        s.avgPerSession = completedInPeriod.isEmpty ? 0 : s.mixSessions / completedInPeriod.count
        s.avgPerClient = allClients.isEmpty ? 0 : s.trackedRevenue / allClients.count
        s.packageAttachPct = allClients.isEmpty ? 0 : Int((Double(clientsWithPackage.count) / Double(allClients.count) * 100).rounded())
        s.noShowRatePct = completedInPeriod.isEmpty ? 0 : Int((Double(noShows) / Double(completedInPeriod.count) * 100).rounded())
        return s
    }
}

// MARK: - CSV export
//
// A shareable statement of everything the window shows. Amounts are raw integers
// (account currency) so the file opens spreadsheet-ready. Sections are laid out as
// blank-line-separated blocks with their own header row — the common statement CSV
// shape that Numbers/Excel/Sheets all import cleanly.

struct FinanceCSV: Transferable {
    let data: Data
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { $0.data }
            .suggestedFileName { $0.name }
    }
}

func financeStatementCSV(_ s: FinanceSummary, period: FinancePeriod, now: Date = Date()) -> Data {
    func esc(_ f: String) -> String {
        (f.contains(",") || f.contains("\"") || f.contains("\n"))
            ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : f
    }
    var lines: [String] = []
    func row(_ cols: String...) { lines.append(cols.map(esc).joined(separator: ",")) }
    func rowA(_ cols: [String]) { lines.append(cols.map(esc).joined(separator: ",")) }
    func opt(_ v: Int?) -> String { v.map(String.init) ?? "" }

    let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short

    row("Flowe finance statement")
    row("Period", period.rawValue)
    row("Generated", df.string(from: now))
    row("Note", "Amounts are in your account currency and tracked (students settle off-app).")
    lines.append("")

    row("Summary", "Amount")
    row("Tracked revenue", String(s.trackedRevenue))
    row("Collected", String(s.collected))
    row("Owed to you", String(s.owedToYou))
    row("Cover pay", String(s.coverPay))
    row("Credit liability", opt(s.creditLiability))
    row("Trend vs previous period (%)", opt(s.trendPct))
    lines.append("")

    row("Revenue mix", "Amount")
    row("Sessions", String(s.mixSessions))
    row("Packages", String(s.mixPackages))
    row("Fees", String(s.mixFees))
    row("Cover", String(s.mixCover))
    lines.append("")

    if !s.offerings.isEmpty {
        row("Packages — offering", "Price", "Sold", "Revenue")
        for o in s.offerings { rowA([o.title, String(o.price), String(o.sold), String(o.revenue)]) }
        lines.append("")
    }

    row("No-Show Shield", "Amount")
    row("Owed", String(s.feesOwed))
    row("Collected", String(s.feesCollected))
    row("Waived", String(s.feesWaived))
    lines.append("")

    if !s.balances.isEmpty {
        row("Student balances", "Remaining", "Total", "Value", "Expires in (days)")
        for b in s.balances { rowA([b.name, String(b.remaining), String(b.total), String(b.value), opt(b.expiresInDays)]) }
        lines.append("")
    }

    if !s.topClients.isEmpty {
        row("Top clients", "Sessions", "Spend")
        for c in s.topClients { rowA([c.name, String(c.sessions), String(c.spend)]) }
        lines.append("")
    }

    row("KPIs", "Value")
    row("Avg per session", String(s.avgPerSession))
    row("Avg per client", String(s.avgPerClient))
    row("Package attach (%)", String(s.packageAttachPct))
    row("No-show rate (%)", String(s.noShowRatePct))

    return Data(lines.joined(separator: "\r\n").utf8)
}

// MARK: - View

struct FinanceCenterView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var period: FinancePeriod = .month

    // Semantic finance colors — deliberately separate from the Flowe pink accent.
    private let pos   = Color(red: 0.18, green: 0.62, blue: 0.27)
    private let warn  = Color(red: 0.87, green: 0.48, blue: 0.05)
    private let liab  = Color(red: 0.55, green: 0.31, blue: 0.62)
    private let cover = Color(red: 0.05, green: 0.56, blue: 0.66)

    private var s: FinanceSummary { data.financeSummary(period) }
    private func money(_ v: Int) -> String { settings.money(v) }

    var body: some View {
        NavigationStack {
            ScrollView {
                let s = self.s
                VStack(spacing: 14) {
                    periodPicker
                    hero(s)
                    tiles(s)
                    if !s.isEmpty { mixCard(s) }
                    packagesSection(s)
                    shieldCard(s)
                    if !s.topClients.isEmpty { topClients(s) }
                    kpis(s)
                    if s.isEmpty { emptyHint } else { exportShare(s) }
                }
                .padding(16)
            }
            .background(Color.flowWhite)
            .navigationTitle("Finance")
            .navigationBarTitleDisplayMode(.inline)
            .task { await data.syncStudentBalances() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep).fontWeight(.semibold)
                }
            }
        }
    }

    private func panel<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.floweBorder, lineWidth: 1))
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(FinancePeriod.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: period) { _, _ in Haptic.selection() }
    }

    private func hero(_ s: FinanceSummary) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text("Tracked revenue").font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted)
                    Spacer()
                    if let t = s.trendPct {
                        Text(verbatim: (t >= 0 ? "↑ " : "↓ ") + "\(abs(t))%")
                            .font(FloweFont.sans(12, .medium)).foregroundStyle(t >= 0 ? pos : warn)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background((t >= 0 ? pos : warn).opacity(0.12), in: Capsule())
                    }
                }
                Text(money(s.trackedRevenue)).font(FloweFont.serif(40, .medium)).foregroundStyle(Color.floweInk)
                HStack(spacing: 6) {
                    Circle().fill(Color.flowePinkDeep).frame(width: 6, height: 6)
                    Text("Tracked — students pay you directly").font(FloweFont.sans(11)).foregroundStyle(Color.floweMuted)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tiles(_ s: FinanceSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            tile("Collected", money(s.collected), "packages + fees in", pos)
            tile("Owed to you", money(s.owedToYou), "unpaid no-show fees", warn)
            tile("Credit liability", s.creditLiability.map(money) ?? "—", s.creditLiability == nil ? "with credit tracking" : "prepaid, unredeemed", liab)
            tile("Cover pay", money(s.coverPay), "coverage ledger", cover)
        }
    }

    private func tile(_ k: LocalizedStringKey, _ v: String, _ sub: LocalizedStringKey, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 9, height: 9)
                Text(k).font(FloweFont.sans(11, .medium)).foregroundStyle(Color.floweMuted)
            }
            Text(v).font(FloweFont.serif(22, .medium)).foregroundStyle(c)
            Text(sub).font(FloweFont.sans(10)).foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.floweCardBg).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.floweBorder, lineWidth: 1))
    }

    private func mixCard(_ s: FinanceSummary) -> some View {
        let segs: [(LocalizedStringKey, Int, Color)] = [("Sessions", s.mixSessions, Color.flowePinkDeep), ("Packages", s.mixPackages, liab), ("Fees", s.mixFees, warn), ("Cover", s.mixCover, cover)]
        let total = max(1, segs.reduce(0) { $0 + $1.1 })
        return panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Where it comes from").font(FloweFont.sans(15, .medium)).foregroundStyle(Color.floweInk)
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                            Rectangle().fill(seg.2).frame(width: geo.size.width * CGFloat(seg.1) / CGFloat(total))
                        }
                    }
                }
                .frame(height: 12).clipShape(Capsule())
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(seg.2).frame(width: 9, height: 9)
                            Text(seg.0).font(FloweFont.sans(12)).foregroundStyle(Color.floweInk)
                            Spacer()
                            Text(money(seg.1)).font(FloweFont.sans(12, .medium)).foregroundStyle(Color.floweInk)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func packagesSection(_ s: FinanceSummary) -> some View {
        SectionHeader(text: "PACKAGES")
        if s.offerings.isEmpty {
            panel { Text("Sell your first class package to see it here.").font(FloweFont.sans(13)).foregroundStyle(Color.floweMuted).frame(maxWidth: .infinity, alignment: .leading) }
        } else {
            panel {
                VStack(spacing: 0) {
                    ForEach(Array(s.offerings.enumerated()), id: \.element.id) { i, o in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.title).font(FloweFont.sans(13, .medium)).foregroundStyle(Color.floweInk)
                                Text(verbatim: "\(money(o.price)) · sold \(o.sold)").font(FloweFont.sans(11)).foregroundStyle(Color.floweMuted)
                            }
                            Spacer()
                            Text(money(o.revenue)).font(FloweFont.sans(13, .medium)).foregroundStyle(Color.floweInk)
                        }
                        .padding(.vertical, 11)
                        if i < s.offerings.count - 1 { Divider().overlay(Color.floweBorder) }
                    }
                }
            }
        }
        // Per-student credit balances (Phase B). Falls back to a hint until /credits/clients is deployed.
        if s.balances.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(liab)
                Text("Per-student credit balances & liability light up with credit tracking.")
                    .font(FloweFont.sans(11)).foregroundStyle(Color.floweMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        } else {
            SectionHeader(text: "STUDENT BALANCES")
            panel {
                VStack(spacing: 0) {
                    ForEach(Array(s.balances.enumerated()), id: \.element.id) { i, b in
                        HStack(spacing: 12) {
                            CreditRing(remaining: b.remaining, total: max(b.total, 1), size: 38, style: .compact)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name.isEmpty ? "Client" : b.name).font(FloweFont.sans(13, .medium)).foregroundStyle(Color.floweInk)
                                if let d = b.expiresInDays, d <= 14 {
                                    Text(verbatim: "Expires in \(d)d").font(FloweFont.sans(10, .medium)).foregroundStyle(warn)
                                }
                            }
                            Spacer()
                            Text(money(b.value)).font(FloweFont.sans(13, .medium)).foregroundStyle(Color.floweInk)
                        }
                        .padding(.vertical, 10)
                        if i < s.balances.count - 1 { Divider().overlay(Color.floweBorder) }
                    }
                }
            }
        }
    }

    private func shieldCard(_ s: FinanceSummary) -> some View {
        VStack(spacing: 8) {
            SectionHeader(text: "NO-SHOW SHIELD")
            panel {
                VStack(spacing: 11) {
                    HStack(spacing: 10) {
                        miniStat(money(s.feesOwed), "Owed", warn)
                        miniStat(money(s.feesCollected), "Collected", pos)
                        miniStat(money(s.feesWaived), "Waived", Color.floweMuted)
                    }
                    if s.feesCollected > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill").font(.system(size: 11)).foregroundStyle(pos)
                            Text(verbatim: "\(money(s.feesCollected)) in fees protected").font(FloweFont.sans(11, .medium)).foregroundStyle(pos)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func miniStat(_ v: String, _ l: LocalizedStringKey, _ c: Color) -> some View {
        VStack(spacing: 1) {
            Text(v).font(FloweFont.serif(16, .medium)).foregroundStyle(c)
            Text(l).font(FloweFont.sans(10)).foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.flowWhite).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func topClients(_ s: FinanceSummary) -> some View {
        VStack(spacing: 8) {
            SectionHeader(text: "TOP CLIENTS")
            panel {
                VStack(spacing: 0) {
                    ForEach(Array(s.topClients.enumerated()), id: \.element.id) { i, cl in
                        HStack(spacing: 12) {
                            AvatarView(id: "", photo: data.studentPhoto(forOwnerID: cl.id), size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cl.name.isEmpty ? "Client" : cl.name).font(FloweFont.sans(13, .medium)).foregroundStyle(Color.floweInk)
                                Text(verbatim: "\(cl.sessions) sessions").font(FloweFont.sans(11)).foregroundStyle(Color.floweMuted)
                            }
                            Spacer()
                            Text(money(cl.spend)).font(FloweFont.sans(13, .medium)).foregroundStyle(Color.floweInk)
                        }
                        .padding(.vertical, 10)
                        if i < s.topClients.count - 1 { Divider().overlay(Color.floweBorder) }
                    }
                }
            }
        }
    }

    private func kpis(_ s: FinanceSummary) -> some View {
        VStack(spacing: 8) {
            SectionHeader(text: "AT A GLANCE")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                kpi(money(s.avgPerSession), "Avg / session")
                kpi(money(s.avgPerClient), "Avg / client")
                kpi("\(s.packageAttachPct)%", "Package attach rate")
                kpi("\(s.noShowRatePct)%", "No-show rate")
            }
        }
    }

    private func kpi(_ v: String, _ l: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(FloweFont.serif(19, .medium)).foregroundStyle(Color.floweInk)
            Text(l).font(FloweFont.sans(11)).foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.floweCardBg).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
    }

    private func exportShare(_ s: FinanceSummary) -> some View {
        ShareLink(
            item: FinanceCSV(data: financeStatementCSV(s, period: period),
                             name: "Flowe-Finance-\(period.rawValue)"),
            preview: SharePreview("Flowe finance statement (\(period.rawValue))")
        ) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                Text("Export statement")
            }
            .font(FloweFont.sans(14, .medium)).foregroundStyle(Color.flowWhite)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.floweInk).clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Haptic.tap() })
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 26)).foregroundStyle(Color.floweMuted)
            Text("No finance activity yet").font(FloweFont.sans(14, .medium)).foregroundStyle(Color.floweInk)
            Text("Completed sessions, package sales and fees show up here.").font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted).multilineTextAlignment(.center)
        }
        .padding(.top, 20)
    }
}
