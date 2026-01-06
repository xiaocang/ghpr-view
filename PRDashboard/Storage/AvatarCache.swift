import Foundation
import AppKit
import os

class AvatarCache {
    static let shared = AvatarCache()

    private let logger = Logger(subsystem: "com.prdashboard", category: "AvatarCache")
    private let cacheDir: URL
    private let memoryCache = NSCache<NSString, NSImage>()

    private init() {
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.prdashboard/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Get cached avatar or fetch from network
    func avatar(for url: URL) async -> NSImage? {
        let key = url.absoluteString as NSString
        let filename = url.lastPathComponent  // GitHub avatar URLs have unique IDs

        // Check memory cache
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        // Check disk cache
        let fileURL = cacheDir.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: fileURL),
           let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: key)
            return image
        }

        // Fetch from network
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = NSImage(data: data) {
                // Save to disk
                try? data.write(to: fileURL, options: .atomic)
                // Save to memory
                memoryCache.setObject(image, forKey: key)
                return image
            }
        } catch {
            logger.debug("Failed to fetch avatar: \(error.localizedDescription)")
        }

        return nil
    }

    func clear() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}
