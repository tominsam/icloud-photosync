import SwiftUI

struct PlanButtons: View {
    var confirm: () -> Void
    var fetchOnly: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            Button(action: confirm) {
                Text("Proceed")
            }
            .buttonStyle(PrimaryButtonStyle())
            if let fetchOnly {
                Button(action: fetchOnly) {
                    Text("Fetch only")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding()
    }
}

#Preview("Both buttons") {
    PlanButtons(confirm: {}, fetchOnly: {})
}

#Preview("Proceed only") {
    PlanButtons(confirm: {})
}
