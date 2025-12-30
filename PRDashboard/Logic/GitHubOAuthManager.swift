import Foundation
import AuthenticationServices
import CommonCrypto

@MainActor
class GitHubOAuthManager: NSObject, ObservableObject {
    // OAuth App credentials - Replace YOUR_CLIENT_ID with your actual Client ID
    // Create at: https://github.com/settings/developers
    // Callback URL: ghpr://oauth/callback
    private let clientID = "Ov23liGCAVv1nOHzVVhf"
    private let redirectURI = "ghpr://oauth/callback"
    private let scope = "repo read:user"

    @Published private(set) var authState: AuthState = .empty
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authError: Error?

    private var codeVerifier: String?
    private var webAuthSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        loadSavedAuth()
    }

    // MARK: - Public Methods

    func signIn() {
        guard !isAuthenticating else { return }

        isAuthenticating = true
        authError = nil

        // Generate PKCE code verifier and challenge
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        codeVerifier = verifier

        // Build authorization URL
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: UUID().uuidString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else {
            isAuthenticating = false
            authError = OAuthError.invalidURL
            return
        }

        // Use ASWebAuthenticationSession for secure OAuth
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "ghpr"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                await self?.handleCallback(callbackURL: callbackURL, error: error)
            }
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webAuthSession = session

        if !session.start() {
            isAuthenticating = false
            authError = OAuthError.sessionStartFailed
        }
    }

    func signOut() {
        KeychainHelper.deleteAuthState()
        authState = .empty
        authError = nil
    }

    func loadSavedAuth() {
        authState = KeychainHelper.loadAuthState()

        // If we have a token but no username, fetch it
        if authState.accessToken != nil && authState.username == nil {
            Task {
                await fetchAndUpdateUsername()
            }
        }
    }

    // MARK: - Private Methods

    private func handleCallback(callbackURL: URL?, error: Error?) async {
        defer { isAuthenticating = false }

        if let error = error {
            if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                // User cancelled, not an error
                return
            }
            authError = error
            return
        }

        guard let callbackURL = callbackURL,
              let code = extractCode(from: callbackURL) else {
            authError = OAuthError.invalidCallback
            return
        }

        do {
            let token = try await exchangeCodeForToken(code: code)
            let username = try await fetchUsername(token: token)

            let newAuthState = AuthState(accessToken: token, username: username)
            try KeychainHelper.saveAuthState(newAuthState)
            authState = newAuthState
        } catch {
            authError = error
        }
    }

    private func fetchAndUpdateUsername() async {
        guard let token = authState.accessToken else { return }

        do {
            let username = try await fetchUsername(token: token)
            var updatedState = authState
            updatedState.username = username
            try KeychainHelper.saveAuthState(updatedState)
            authState = updatedState
        } catch {
            // Silently fail - we still have the token
        }
    }

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64URLEncodedString()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64URLEncodedString()
    }

    private func extractCode(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private func exchangeCodeForToken(code: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier ?? ""
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed("HTTP error")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        guard let token = tokenResponse.accessToken else {
            throw OAuthError.tokenExchangeFailed(tokenResponse.error ?? "Unknown error")
        }

        return token
    }

    private func fetchUsername(token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OAuthError.userFetchFailed
        }

        let user = try JSONDecoder().decode(GitHubUser.self, from: data)
        return user.login
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GitHubOAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Supporting Types

enum OAuthError: LocalizedError {
    case invalidURL
    case invalidCallback
    case sessionStartFailed
    case tokenExchangeFailed(String)
    case userFetchFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to build authorization URL"
        case .invalidCallback:
            return "Invalid OAuth callback URL"
        case .sessionStartFailed:
            return "Failed to start authentication session"
        case .tokenExchangeFailed(let reason):
            return "Failed to exchange code for token: \(reason)"
        case .userFetchFailed:
            return "Failed to fetch user information"
        }
    }
}

private struct TokenResponse: Codable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case error
        case errorDescription = "error_description"
    }
}

private struct GitHubUser: Codable {
    let login: String
}

// MARK: - Data Extension for Base64URL

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
