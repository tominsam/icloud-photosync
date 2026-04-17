import SwiftUI

struct StateLabel: View {
    let leading: String
    let state: TaskProgress?

    var body: some View {
        HStack {
            Text(leading).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(state?.stringState ?? "")
                .monospacedDigit()
        }
        .padding([.leading, .trailing])
        .padding([.top, .bottom], 12)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // background is a progress bar that fills up behind the label
            GeometryReader { metrics in
                if let progress = state?.progressPercent {
                    Color.green
                        .opacity(state?.opacity ?? 0)
                        .frame(width: metrics.size.width * progress)
                }
            }
        }
    }

}

private extension TaskProgress {
    var stringState: String {
        if complete {
            if let total, total >= 0 {
                return "Complete (\(total))"
            } else {
                return "Complete"
            }
        } else if let total {
            return "\(progress) / \(total)"
        } else {
            return "\(progress) / …"
        }
    }

    var progressPercent: Double? {
        if complete {
            return 1
        }
        if total == 0 || total == nil {
            return nil
        }
        return max(Double(progress) / Double(total ?? 1), 0)
    }
    
    var opacity: Double {
        guard let total else { return 0 }
        if total < 0 {
            return 0.3
        } else if complete {
            return 0.1
        } else {
            return 0.3
        }
    }
}

#Preview {
    VStack {
        StateLabel(leading: "State", state: makeState(5, total: nil))
        StateLabel(leading: "State", state: makeState(1))
        StateLabel(leading: "State", state: makeState(5))
        StateLabel(leading: "State", state: makeState(10))
        StateLabel(leading: "State", state: makeState(10, complete: true))
    }
}

@MainActor
private func makeState(
    _ progress: Int,
    total: Int? = 10,
    complete: Bool = false
) -> TaskProgress {
    let state = ProgressManager().createTask(named: "Demo", total: total, category: .fetch)
    state.progress = progress
    if complete {
        state.setComplete()
    }
    return state
}
