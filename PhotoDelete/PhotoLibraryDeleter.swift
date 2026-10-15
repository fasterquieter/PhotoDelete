import Combine
import Photos
import UIKit

enum DeletionBatch: String, CaseIterable, Identifiable {
    case fiveHundred
    case twoThousand
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHundred: "500"
        case .twoThousand: "2,000"
        case .all: "All"
        }
    }

    var detail: String {
        switch self {
        case .fiveHundred:
            "One system confirmation for every 500 items."
        case .twoThousand:
            "One system confirmation for every 2,000 items."
        case .all:
            "One confirmation for the whole library. If Photos rejects it, deletion continues in smaller batches."
        }
    }

    var confirmationPhrase: String {
        switch self {
        case .fiveHundred: "each batch of 500"
        case .twoThousand: "each batch of 2,000"
        case .all: "once for the whole library"
        }
    }

    func size(for total: Int) -> Int {
        switch self {
        case .fiveHundred: 500
        case .twoThousand: 2_000
        case .all: max(total, 1)
        }
    }
}

struct LibraryCounts: Equatable {
    var photographs = 0
    var videos = 0
    var total = 0

    var other: Int { max(0, total - photographs - videos) }
}

struct TestPhoto: Equatable {
    var localIdentifier: String
    var filename: String
    var created: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var isLivePhoto: Bool
    var isHidden: Bool

    var detail: String {
        var lines = [filename]
        if let created {
            lines.append(created.formatted(date: .abbreviated, time: .shortened))
        }
        if pixelWidth > 0, pixelHeight > 0 {
            lines.append("\(pixelWidth) × \(pixelHeight)")
        }
        if isLivePhoto {
            lines.append("Live Photo")
        }
        if isHidden {
            lines.append("Hidden")
        }
        return lines.joined(separator: "\n")
    }
}

/// Local PhotoKit operations only. This type never requests image bytes,
/// never allows network access, and never calls iCloud identifier or upload APIs.
enum PhotoLibraryClient {
    static func makeOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.wantsIncrementalChangeDetails = false
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        if #available(iOS 27.0, *) {
            options.prefetchAssetExtendedMetadata = false
        }
        return options
    }

    static func counts() -> LibraryCounts {
        let options = makeOptions()
        let photographs = PHAsset.fetchAssets(with: .image, options: options).count
        let videos = PHAsset.fetchAssets(with: .video, options: options).count
        let total = PHAsset.fetchAssets(with: options).count
        return LibraryCounts(photographs: photographs, videos: videos, total: total)
    }

    static func onePhotograph() -> TestPhoto? {
        if let visible = firstPhotograph(includeHidden: false) {
            return visible
        }
        return firstPhotograph(includeHidden: true)
    }

    static func delete(identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        let existing = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: makeOptions()).count
        guard existing > 0 else { return }

        let ids = identifiers
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.makeOptions())
                guard assets.count > 0 else { return }
                PHAssetChangeRequest.deleteAssets(assets)
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else if let error {
                    continuation.resume(throwing: error as NSError)
                } else {
                    continuation.resume(throwing: unknownFailure)
                }
            })
        }
    }

    private static func firstPhotograph(includeHidden: Bool) -> TestPhoto? {
        let options = makeOptions()
        options.includeHiddenAssets = includeHidden
        options.includeAllBurstAssets = false
        options.fetchLimit = 1
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        guard result.count > 0 else { return nil }
        let asset = result.object(at: 0)
        guard !asset.sourceType.contains(.typeCloudShared) else { return nil }

        return TestPhoto(
            localIdentifier: asset.localIdentifier,
            filename: filename(for: asset),
            created: asset.creationDate,
            pixelWidth: Int(asset.pixelWidth),
            pixelHeight: Int(asset.pixelHeight),
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isHidden: asset.isHidden
        )
    }

    /// Filename only. Does not request the file through PHAssetResourceManager.
    private static func filename(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred = resources.first { $0.type == .photo } ?? resources.first { $0.type == .fullSizePhoto }
        if let preferred, let name = filename(of: preferred) {
            return name
        }
        for resource in resources where resource.type != .adjustmentData {
            if let name = filename(of: resource) {
                return name
            }
        }
        return "Unnamed photograph"
    }

    private static func filename(of resource: PHAssetResource) -> String? {
        if #available(iOS 27.0, *) {
            if let name = resource.filename, !name.isEmpty {
                return name
            }
        }
        let legacy = resource.originalFilename
        return legacy.isEmpty ? nil : legacy
    }

    fileprivate static let unknownFailure = NSError(
        domain: PHPhotosErrorDomain,
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Photos did not finish deleting that batch."]
    )
}

@MainActor
final class PhotoLibraryDeleter: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus
    @Published private(set) var counts = LibraryCounts()
    @Published private(set) var countsLoaded = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isDeletingAll = false
    @Published private(set) var isReading = false
    @Published private(set) var stopRequested = false
    @Published private(set) var processed = 0
    @Published private(set) var remaining = 0
    @Published private(set) var failed = 0
    @Published private(set) var snapshotTotal = 0
    @Published private(set) var statusText: String?
    @Published private(set) var errorText: String?
    @Published private(set) var testDeletion: TestPhoto?
    @Published var batchChoice: DeletionBatch = .twoThousand
    @Published var confirmDeleteAll = false
    @Published var confirmTest = false
    @Published private(set) var pendingTest: TestPhoto?

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var showsSettings: Bool {
        switch authorization {
        case .denied, .restricted, .limited:
            return true
        default:
            return false
        }
    }

    var libraryIsEmpty: Bool {
        authorization == .authorized && countsLoaded && counts.total == 0
    }

    func refreshOnForeground() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized, !isDeleting, !isPreparing else { return }
        reloadCounts()
    }

    func requestTest() async {
        guard !isDeleting, !isPreparing, !confirmTest, !confirmDeleteAll else { return }
        isPreparing = true
        errorText = nil
        defer { isPreparing = false }

        let status = await resolveAuthorization()
        authorization = status
        guard status == .authorized else {
            errorText = Self.accessMessage(status)
            return
        }

        guard let photo = PhotoLibraryClient.onePhotograph() else {
            errorText = "No photograph was found in the local library."
            return
        }
        pendingTest = photo
        confirmTest = true
    }

    func deletePendingTest() async {
        guard let photo = pendingTest, !isDeleting else { return }
        pendingTest = nil
        testDeletion = nil
        isDeleting = true
        stopRequested = false
        processed = 0
        failed = 0
        snapshotTotal = 1
        remaining = 1
        errorText = nil
        statusText = "Waiting for the system confirmation for 1 photograph."
        beginGuardingSleep()
        defer { finishOperation() }

        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !stopRequested else {
            snapshotTotal = 0
            processed = 0
            remaining = 0
            statusText = "Stopped. Nothing was deleted."
            return
        }

        do {
            try await PhotoLibraryClient.delete(identifiers: [photo.localIdentifier])
            processed = 1
            remaining = 0
            testDeletion = photo
            statusText = "Test finished. 1 photograph was deleted from this device."
        } catch {
            snapshotTotal = 0
            processed = 0
            remaining = 0
            if Self.isUserCancel(error) || stopRequested {
                statusText = "Test cancelled. Nothing was deleted."
            } else {
                errorText = Self.message(for: error)
                statusText = "The test did not delete the photograph."
            }
        }
        reloadCounts()
    }

    func requestDeleteAll() async {
        guard !isDeleting, !isPreparing, !confirmTest, !confirmDeleteAll else { return }
        isPreparing = true
        errorText = nil
        defer { isPreparing = false }

        let status = await resolveAuthorization()
        authorization = status
        guard status == .authorized else {
            errorText = Self.accessMessage(status)
            return
        }

        reloadCounts()
        guard counts.total > 0 else {
            statusText = "No photographs or videos are in the local library."
            return
        }
        confirmDeleteAll = true
    }

    func deleteAll() async {
        guard !isDeleting else { return }
        testDeletion = nil
        isDeleting = true
        isDeletingAll = true
        stopRequested = false
        processed = 0
        failed = 0
        snapshotTotal = 0
        remaining = 0
        errorText = nil
        statusText = "Reading the library…"
        beginGuardingSleep()
        defer { finishOperation() }

        guard let identifiers = await readIdentifiers() else {
            statusText = "Stopped before anything was deleted."
            reloadCounts()
            return
        }

        snapshotTotal = identifiers.count
        remaining = identifiers.count
        guard !identifiers.isEmpty else {
            statusText = "No photographs or videos are in the local library."
            reloadCounts()
            return
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !stopRequested else {
            statusText = "Stopped before anything was deleted."
            reloadCounts()
            return
        }

        var size = batchChoice.size(for: identifiers.count)
        var index = 0
        var interruptedRetries = 0
        var safety = 0
        let safetyLimit = identifiers.count * 4 + 10
        var halted = false

        while index < identifiers.count {
            if stopRequested {
                halted = true
                break
            }
            safety += 1
            if safety > safetyLimit {
                errorText = "Stopped because deletion was not making progress."
                halted = true
                break
            }

            let end = min(index + size, identifiers.count)
            let batch = Array(identifiers[index..<end])
            statusText = "Deleting \(batch.count.formatted()) at a time. Confirm the system prompt if iOS shows one."
            processed = index
            remaining = identifiers.count - index
            await Task.yield()

            do {
                try await PhotoLibraryClient.delete(identifiers: batch)
                index = end
                processed = index
                remaining = identifiers.count - index
                interruptedRetries = 0
                if failed == 0 {
                    errorText = nil
                }
                reloadCounts()
            } catch {
                if Self.isUserCancel(error) {
                    halted = true
                    break
                }
                if Self.shouldStop(error) {
                    errorText = Self.message(for: error)
                    halted = true
                    break
                }
                if Self.isInterrupted(error), interruptedRetries < 2 {
                    interruptedRetries += 1
                    errorText = "Photos interrupted this batch. Retrying."
                    continue
                }
                interruptedRetries = 0
                if batch.count > 1 {
                    size = max(1, batch.count / 2)
                    errorText = "A batch of \(batch.count.formatted()) failed: \(Self.describe(error)) Continuing with \(size.formatted()) at a time."
                    continue
                }
                failed += 1
                index += 1
                processed = index
                remaining = identifiers.count - index
                errorText = "Could not delete 1 item: \(Self.describe(error))"
            }
        }

        reloadCounts()
        if counts.total == 0 && !halted && failed == 0 {
            remaining = 0
            statusText = "Finished. The local library has no photographs or videos left. Empty Recently Deleted in the Photos app to free storage."
        } else if halted && errorText == nil {
            statusText = "Stopped. \(processed.formatted()) processed, \(remaining.formatted()) not yet processed. Tap Delete All to continue with what remains."
        } else if halted {
            statusText = "Stopped. Already deleted items stay deleted. Tap Delete All to continue with what remains."
        } else if failed > 0 {
            statusText = "Finished this pass with \(failed.formatted()) not deleted. \(counts.total.formatted()) remain in the local library. Tap Delete All to try again."
            remaining = counts.total
        } else if counts.total > 0 {
            statusText = "Finished this pass. \(counts.total.formatted()) items are still in the local library. Tap Delete All to continue."
            remaining = counts.total
        } else {
            statusText = "Finished. Empty Recently Deleted in the Photos app to free storage."
        }
    }

    func stop() {
        guard isDeleting, !stopRequested else { return }
        stopRequested = true
        statusText = "Stopping after the current batch…"
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func readIdentifiers() async -> [String]? {
        isReading = true
        defer { isReading = false }

        let result = PHAsset.fetchAssets(with: PhotoLibraryClient.makeOptions())
        let total = result.count
        var identifiers: [String] = []
        identifiers.reserveCapacity(total)
        var photographs = 0
        var videos = 0
        var index = 0

        while index < total {
            if stopRequested { return nil }
            let upper = min(index + 400, total)
            autoreleasepool {
                for offset in index..<upper {
                    let asset = result.object(at: offset)
                    if asset.sourceType.contains(.typeCloudShared) { continue }
                    identifiers.append(asset.localIdentifier)
                    switch asset.mediaType {
                    case .image:
                        photographs += 1
                    case .video:
                        videos += 1
                    default:
                        break
                    }
                }
            }
            index = upper
            statusText = "Reading the library… \(index.formatted()) of \(total.formatted())"
            await Task.yield()
        }

        counts = LibraryCounts(photographs: photographs, videos: videos, total: identifiers.count)
        countsLoaded = true
        return identifiers
    }

    private func reloadCounts() {
        guard authorization == .authorized else { return }
        counts = PhotoLibraryClient.counts()
        countsLoaded = true
    }

    private func resolveAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private func beginGuardingSleep() {
        UIApplication.shared.isIdleTimerDisabled = true
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PhotoDelete") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }
    }

    private func finishOperation() {
        isDeleting = false
        isDeletingAll = false
        isReading = false
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        let identifier = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private static func accessMessage(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return ""
        case .limited:
            return "Full Photo Access is required. Limited access would delete only items you picked, not the library on this device. Open Settings, tap PhotoDelete, then Photos, and choose Full Access."
        case .denied:
            return "Photo access is off. Open Settings, tap PhotoDelete, then Photos, and choose Full Access."
        case .restricted:
            return "Photo access is restricted on this device, so nothing can be deleted."
        case .notDetermined:
            return "Photo access is required before anything can be deleted."
        @unknown default:
            return "Photo access is not available."
        }
    }

    private static func isUserCancel(_ error: Error) -> Bool {
        let nsError = error as NSError
        let cancelledDomains = [NSCocoaErrorDomain, PHPhotosErrorDomain]
        return nsError.code == NSUserCancelledError && cancelledDomains.contains(nsError.domain)
    }

    private static func isInterrupted(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain && nsError.code == 3301
    }

    private static func shouldStop(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain else { return false }
        switch nsError.code {
        case 3114, 3142, 3143, 3164, 3305, 3310, 3311:
            return true
        default:
            return false
        }
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain else { return describe(error) }
        switch nsError.code {
        case 3164:
            return "Photos asked to download an original from iCloud. PhotoDelete did not download it, and this batch was not deleted."
        case 3305:
            return "Photos reported there is not enough free space to continue. Remove other files from this device and try again. Items already deleted stay deleted."
        case 3310, 3311:
            return "Photo access was denied. Allow Full Access in Settings, then try again."
        case 3114, 3142, 3143:
            return "The photo library became unavailable. \(describe(error))"
        default:
            return describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain {
            return "\(nsError.localizedDescription) (Photos error \(nsError.code))"
        }
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }
}
