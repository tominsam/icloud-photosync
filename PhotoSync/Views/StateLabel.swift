import SwiftUI

struct StateLabel: View {
    let leading: String
    let state: TaskProgress

    var body: some View {
        HStack {
            Text(leading).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(state.stringState)
        }
        .padding([.leading, .trailing])
        .padding([.top, .bottom], 12)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // background is a progress bar that fills up behind the label
            GeometryReader { metrics in
                if let progress = state.progressPercent {
                    Color.green
                        .opacity(state.complete ? 0.1 : 0.3)
                        .frame(width: metrics.size.width * progress)
                }
            }
        }
    }

}

private extension TaskProgress {
    var stringState: String {
        if complete {
            return "Complete (\(total))"
        } else {
            return "\(progress) / \(total)"
        }
    }

    var progressPercent: Double? {
        if complete {
            return 1
        }
        if total == 0 {
            return nil
        }
        return Double(progress) / Double(total)
    }
}

#Preview {
    VStack {
        StateLabel(leading: "State", state: makeState(1))
        StateLabel(leading: "State", state: makeState(5))
        StateLabel(leading: "State", state: makeState(10))
        StateLabel(leading: "State", state: makeState(10, complete: true))
    }
}

@MainActor
private func makeState(_ progress: Int, complete: Bool = false) -> TaskProgress {
    var state = ProgressManager(notify: { _ in }).createTask(named: "Demo", total: 10)
    state.progress = progress
    if complete {
        state.setComplete()
    }
    return state
}
