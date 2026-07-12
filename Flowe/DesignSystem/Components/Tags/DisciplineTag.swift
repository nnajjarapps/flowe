import SwiftUI

enum Discipline: String, CaseIterable, Codable {
    case mat       = "Mat"
    case reformer  = "Reformer"
    case barre     = "Barre"
    case prenatal  = "Prenatal"

    var backgroundColor: Color {
        switch self {
        case .mat:      return .flowBlushPink
        case .reformer: return .flowDustyRose.opacity(0.25)
        case .barre:    return .flowWarmGray
        case .prenatal: return .flowLightBeige
        }
    }
}

struct DisciplineTag: View {
    let discipline: Discipline

    var body: some View {
        Text(discipline.rawValue)
            .flowFont(.label)
            .foregroundStyle(Color.flowEspressoBrown)
            .padding(.horizontal, FlowSpacing.sm)
            .padding(.vertical, FlowSpacing.xs)
            .background(discipline.backgroundColor)
            .clipShape(Capsule())
    }
}

#Preview {
    HStack {
        ForEach(Discipline.allCases, id: \.self) { DisciplineTag(discipline: $0) }
    }
    .padding()
}
