import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(Color.green.opacity(configuration.isPressed ? 0.4 : 0.7))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(.rect)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(.clear)
            .foregroundStyle(Color.green.opacity(configuration.isPressed ? 0.4 : 0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(.rect)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.green.opacity(configuration.isPressed ? 0.4 : 0.8), lineWidth: 1.5)
            )
    }
}

#Preview {
    VStack(spacing: 16) {
        Button("Primary button") {}
            .buttonStyle(PrimaryButtonStyle())
        Button("Secondary button") {}
            .buttonStyle(SecondaryButtonStyle())
        Button("Primary disabled") {}
            .buttonStyle(PrimaryButtonStyle())
            .disabled(true)
    }
    .padding()
}
