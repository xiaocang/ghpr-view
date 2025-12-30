import SwiftUI

struct Badge: View {
    let count: Int
    var color: Color = .red

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(Capsule())
                .animation(.spring(response: 0.25), value: count)
        }
    }
}

struct DraftBadge: View {
    var body: some View {
        Text("Draft")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
    }
}

#Preview {
    VStack(spacing: 10) {
        Badge(count: 5)
        Badge(count: 99)
        Badge(count: 100)
        DraftBadge()
    }
    .padding()
}
