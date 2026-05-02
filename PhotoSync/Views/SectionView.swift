import SwiftUI

struct SectionView: View {
    var title: String
    var states: [TaskProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !states.isEmpty {
                Text(title)
                    .headerStyle()
                    .padding(.horizontal)

                ForEach(states) { state in
                    StateLabel(leading: state.name, state: state)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity).animation(.easeOut),
                                removal: .opacity
                            )
                        )
                }
            }
        }.animation(.easeInOut, value: states.map(\.id))
    }
}
