import Foundation
import ImageIO
import UIKit

/// SwiftUI 图片任务与共享缓存共同使用的稳定身份。
///
/// resourceID 可能只是远端 session/media/path；必须同时带 Profile，避免两台 Mac 使用相同
/// ID 时复用旧视图任务或已解码图片。
struct MediaRequestIdentity: Hashable, Sendable {
    let profileID: String
    let resourceID: String

    init(profileID: String, resourceID: String) {
        let trimmedProfileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profileID = trimmedProfileID.isEmpty ? "legacy" : trimmedProfileID
        self.resourceID = resourceID
    }
}

/// 统一处理对话与附件中的 data URL 图片，避免 SwiftUI `body` 重算时反复做 Base64 和图片解码。
enum DataURLImageDecoder {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // data URL 已经同时存在于消息模型中，缓存只保留有限的解码结果，避免长会话内存持续增长。
        cache.totalCostLimit = 48 * 1_024 * 1_024
        cache.countLimit = 32
        return cache
    }()

    static func image(
        from value: String,
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int
    ) async -> UIImage? {
        guard !Task.isCancelled else {
            return nil
        }
        let boundedPixelSize = max(1, maxPixelSize)
        let resolvedCacheKey = Self.resolvedCacheKey(
            kind: "data",
            profileID: profileID,
            cacheKey: cacheKey,
            maxPixelSize: boundedPixelSize
        )
        if let cached = cache.object(forKey: resolvedCacheKey) {
            return cached
        }
        await Task.yield()
        guard !Task.isCancelled else {
            return nil
        }

        let decodeTask = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let data = decodedData(from: value),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: boundedPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard !Task.isCancelled,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else {
                return nil
            }

            guard !Task.isCancelled else {
                return nil
            }
            let image = UIImage(cgImage: cgImage)
            let cost = cgImage.bytesPerRow * cgImage.height
            cache.setObject(image, forKey: resolvedCacheKey, cost: cost)
            return image
        }
        // `.task(id:)` 被新来源替换或视图消失时，把取消继续传给后台解码，避免无效图片继续占 CPU。
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    static func image(
        fromFileURL url: URL,
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int
    ) async -> UIImage? {
        guard !Task.isCancelled else {
            return nil
        }
        let boundedPixelSize = max(1, maxPixelSize)
        let resolvedCacheKey = Self.resolvedCacheKey(
            kind: "file",
            profileID: profileID,
            cacheKey: cacheKey,
            maxPixelSize: boundedPixelSize
        )
        if let cached = cache.object(forKey: resolvedCacheKey) {
            return cached
        }

        let decodeTask = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else {
                return nil
            }
            return makeThumbnail(
                from: source,
                cache: cache,
                cacheKey: resolvedCacheKey,
                maxPixelSize: boundedPixelSize
            )
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    /// 只读取已解码缓存，不在 SwiftUI 初始化或 `body` 路径执行 Base64/ImageIO 工作。
    static func cachedImage(
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int,
        fromFile: Bool = false
    ) -> UIImage? {
        let boundedPixelSize = max(1, maxPixelSize)
        return cache.object(
            forKey: Self.resolvedCacheKey(
                kind: fromFile ? "file" : "data",
                profileID: profileID,
                cacheKey: cacheKey,
                maxPixelSize: boundedPixelSize
            )
        )
    }

#if DEBUG
    static func removeAllCachedImagesForTesting() {
        cache.removeAllObjects()
    }
#endif

    private static func decodedData(from value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil,
              let comma = trimmed.firstIndex(of: ",")
        else {
            return nil
        }
        let payload = trimmed[trimmed.index(after: comma)...]
        return Data(base64Encoded: String(payload), options: [.ignoreUnknownCharacters])
    }

    private static func resolvedCacheKey(
        kind: String,
        profileID: String,
        cacheKey: String,
        maxPixelSize: Int
    ) -> NSString {
        let identity = MediaRequestIdentity(
            profileID: profileID,
            resourceID: cacheKey
        )
        // 长度前缀避免 Profile/资源字符串含分隔符时发生组合键碰撞；只存在进程内，不落盘。
        return "\(identity.profileID.utf8.count):\(identity.profileID):\(kind):\(cacheKey):\(maxPixelSize)" as NSString
    }
}

/// HTTP(S) 对话图片加载器。先下载受控大小的数据，再通过 ImageIO 下采样成列表预览图，
/// 从而既能拿到真实宽高用于内容尺寸布局，也不会把超大原图直接解码进会话列表。
enum RemoteURLImageLoader {
    private static let maximumDownloadBytes = 32 * 1_024 * 1_024
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1_024 * 1_024
        cache.countLimit = 32
        return cache
    }()

    static func image(
        from url: URL,
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int,
        session: URLSession = .shared
    ) async -> UIImage? {
        guard !Task.isCancelled else {
            return nil
        }
        let boundedPixelSize = max(1, maxPixelSize)
        let resolvedCacheKey = Self.resolvedCacheKey(
            profileID: profileID,
            cacheKey: cacheKey,
            maxPixelSize: boundedPixelSize
        )
        if let cached = cache.object(forKey: resolvedCacheKey) {
            return cached
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.cachePolicy = .useProtocolCachePolicy
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  data.count <= maximumDownloadBytes
            else {
                return nil
            }

            let decodeTask = Task<UIImage?, Never>.detached(priority: .userInitiated) {
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithData(data as CFData, nil)
                else {
                    return nil
                }
                return makeThumbnail(
                    from: source,
                    cache: cache,
                    cacheKey: resolvedCacheKey,
                    maxPixelSize: boundedPixelSize
                )
            }
            return await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
        } catch {
            return nil
        }
    }

    static func cachedImage(
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int
    ) -> UIImage? {
        cache.object(
            forKey: Self.resolvedCacheKey(
                profileID: profileID,
                cacheKey: cacheKey,
                maxPixelSize: max(1, maxPixelSize)
            )
        )
    }

#if DEBUG
    static func storeImageForTesting(
        _ image: UIImage,
        cacheKey: String,
        profileID: String = "legacy",
        maxPixelSize: Int
    ) {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        cache.setObject(
            image,
            forKey: Self.resolvedCacheKey(
                profileID: profileID,
                cacheKey: cacheKey,
                maxPixelSize: max(1, maxPixelSize)
            ),
            cost: pixelWidth * pixelHeight * 4
        )
    }

    static func removeAllCachedImagesForTesting() {
        cache.removeAllObjects()
    }
#endif

    private static func resolvedCacheKey(
        profileID: String,
        cacheKey: String,
        maxPixelSize: Int
    ) -> NSString {
        let identity = MediaRequestIdentity(profileID: profileID, resourceID: cacheKey)
        return "\(identity.profileID.utf8.count):\(identity.profileID):remote:\(cacheKey):\(maxPixelSize)" as NSString
    }
}


/// 两个加载器（data URL 与远程 URL）此前各复制了一份完全相同的缩略图构造与缓存写入，
/// 只有 CGImageSource 的来源不同。缓存由调用方传入，因为它分别属于各自的 enum。
private func makeThumbnail(
    from source: CGImageSource,
    cache: NSCache<NSString, UIImage>,
    cacheKey: NSString,
    maxPixelSize: Int
) -> UIImage? {
    guard !Task.isCancelled else {
        return nil
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    let image = UIImage(cgImage: cgImage)
    cache.setObject(image, forKey: cacheKey, cost: cgImage.bytesPerRow * cgImage.height)
    return image
}
