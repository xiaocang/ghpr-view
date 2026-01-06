import SwiftUI

struct PRRowView: View {
    let pr: PullRequest
    let onOpen: () -> Void
    let onCopyURL: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Author avatar
            CachedAvatarView(url: pr.authorAvatarURL, authorInitial: pr.author)
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                // Repo and PR number
                HStack(spacing: 4) {
                    Text(pr.repoFullName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("#\(pr.number)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                // PR title
                Text(pr.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                // Author and badges
                HStack(spacing: 6) {
                    Text(pr.author)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if pr.isDraft {
                        DraftBadge()
                    }

                    Spacer()

                    if let ciStatus = pr.ciStatus {
                        CIStatusIcon(
                            status: ciStatus,
                            successCount: pr.checkSuccessCount,
                            failureCount: pr.checkFailureCount,
                            pendingCount: pr.checkPendingCount
                        )
                    }

                    if pr.unresolvedCount > 0 {
                        Badge(count: pr.unresolvedCount)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onOpen()
        }
        .contextMenu {
            Button("Open in Browser") {
                onOpen()
            }
            Button("Copy URL") {
                onCopyURL()
            }
        }
    }
}

#Preview {
    PRRowView(
        pr: PullRequest(
            id: 1,
            number: 123,
            title: "Add new feature for user authentication with OAuth 2.0",
            author: "xiaocang",
            authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"),
            repositoryOwner: "owner",
            repositoryName: "repo",
            url: URL(string: "https://github.com/owner/repo/pull/123")!,
            state: .open,
            isDraft: true,
            createdAt: Date(),
            updatedAt: Date(),
            reviewThreads: [
                ReviewThread(id: "1", isResolved: false, isOutdated: false, path: nil, line: nil, comments: [])
            ],
            category: .authored,
            ciStatus: .failure,
            checkSuccessCount: 3,
            checkFailureCount: 2,
            checkPendingCount: 0
        ),
        onOpen: {},
        onCopyURL: {}
    )
    .frame(width: 350)
    .padding()
}
