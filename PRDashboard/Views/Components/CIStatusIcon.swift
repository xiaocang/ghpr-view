import SwiftUI

struct CIStatusIcon: View {
    let status: CIStatus
    var successCount: Int = 0
    var failureCount: Int = 0
    var pendingCount: Int = 0

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(iconColor)

            // Show counts for failure or pending status
            if status == .failure || status == .pending {
                Text(countText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(iconColor)
            }
        }
    }

    private var iconName: String {
        switch status {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        case .pending:
            return "clock.circle.fill"
        case .expected:
            return "circle.dashed"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch status {
        case .success:
            return .green
        case .failure:
            return .red
        case .pending:
            return .yellow
        case .expected:
            return .secondary
        case .unknown:
            return .orange
        }
    }

    private var countText: String {
        let total = successCount + failureCount + pendingCount
        if total == 0 {
            return ""
        }
        return "\(successCount)/\(total)"
    }
}

#Preview {
    VStack(spacing: 10) {
        HStack {
            CIStatusIcon(status: .success, successCount: 5, failureCount: 0, pendingCount: 0)
            Text("Success (5/5)")
        }
        HStack {
            CIStatusIcon(status: .failure, successCount: 3, failureCount: 2, pendingCount: 0)
            Text("Failure (3/5)")
        }
        HStack {
            CIStatusIcon(status: .pending, successCount: 2, failureCount: 0, pendingCount: 3)
            Text("Pending (2/5)")
        }
        HStack {
            CIStatusIcon(status: .expected)
            Text("Expected")
        }
        HStack {
            CIStatusIcon(status: .unknown, successCount: 10, failureCount: 0, pendingCount: 0)
            Text("Unknown (limit reached)")
        }
    }
    .padding()
}
