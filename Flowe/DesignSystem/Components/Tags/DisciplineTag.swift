import SwiftUI

enum Discipline: String, CaseIterable, Codable {
    case mat       = "Mat"
    case reformer  = "Reformer"
    case barre     = "Barre"
    case prenatal  = "Prenatal"

    var backgroundColor: Color {
        switch self {
        case .mat:      return .flowePinkSoft.opacity(0.30)
        case .reformer: return .flowePink.opacity(0.18)
        case .barre:    return .flowePinkPale.opacity(0.35)
        case .prenatal: return .floweCardBg
        }
    }
}

struct DisciplineTag: View {
    let discipline: Discipline

    var body: some View {
        Text(localizedTag: discipline.rawValue)
            .flowFont(.label)
            .foregroundStyle(Color.flowePinkDeep)
            .padding(.horizontal, FlowSpacing.sm)
            .padding(.vertical, FlowSpacing.xs)
            .background(discipline.backgroundColor)
            .clipShape(Capsule())
    }
}
