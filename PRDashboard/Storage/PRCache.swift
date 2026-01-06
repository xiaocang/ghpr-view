import Foundation
import os

class PRCache {
    static let shared = PRCache()

    private let logger = Logger(subsystem: "com.prdashboard", category: "PRCache")
    private let cacheURL: URL
    private let maxAge: TimeInterval = 3600  // 1 hour

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.prdashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheURL = cacheDir.appendingPathComponent("pr_cache.json")
    }

    func save(_ prList: PRList) {
        do {
            let data = try JSONEncoder().encode(prList)
            try data.write(to: cacheURL, options: .atomic)
            logger.debug("Saved \(prList.pullRequests.count) PRs to cache")
        } catch {
            logger.error("Failed to save cache: \(error.localizedDescription)")
        }
    }

    /// Load cache. If ignoreExpiry is true, returns cache even if > 1 hour old (for fallback)
    func load(ignoreExpiry: Bool = false) -> PRList? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: cacheURL)
            let prList = try JSONDecoder().decode(PRList.self, from: data)

            // Check expiry (1 hour) unless ignoring for fallback
            if !ignoreExpiry && Date().timeIntervalSince(prList.lastUpdated) > maxAge {
                logger.info("Cache expired (older than 1 hour)")
                return nil
            }

            logger.debug("Loaded \(prList.pullRequests.count) PRs from cache")
            return prList
        } catch {
            // Corrupted cache - silently delete
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: cacheURL)
        logger.debug("Cache cleared")
    }
}
