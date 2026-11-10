import CryptoKit
import Foundation

/// The provisioner of the app: ipsw.me and the IPSW download with `URLSession`, the install with
/// the Virtualization framework (docs/virtual-machines.md › macOS versions, › Download, › Install).
public struct SystemVMImageProvisioner: VMImageProvisioning {
    public init() {}

    public var supportsVirtualMachines: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public func versionList() async throws -> Data {
        var request = URLRequest(url: MacOSVersions.listURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: MacOSVersions.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw VMImageFailure("HTTP \(status)")
        }
        return data
    }

    public func download(_ version: MacOSVersion, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: version.url) else {
            throw VMImageFailure("The download failed: the URL of the IPSW is not valid.")
        }
        let download = IPSWDownload(file: file, expectedSHA256: version.sha256, listedSize: Int64(version.sizeBytes), progress: progress)
        try await download.run(url)
    }

    public func install(_ request: VMImageInstallRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        #if arch(arm64)
        try await MacVMInstaller.install(request, progress: progress)
        #else
        throw VMImageFailure.needsAppleSilicon
        #endif
    }

    @MainActor public func makeMachine(_ request: GuestMachineRequest) throws -> any GuestMachine {
        #if arch(arm64)
        return try MacGuestMachine(request)
        #else
        throw VMImageFailure.needsAppleSilicon
        #endif
    }
}

/// One download of an IPSW: the bytes are written to the file as they arrive and hashed on the
/// way (docs/virtual-machines.md › Download). Its delegate methods run on the session's serial
/// queue.
final class IPSWDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The request fails after this time without data; it has no overall timeout.
    static let idleTimeout: TimeInterval = 60

    private let file: URL
    private let expectedSHA256: String?
    private let listedSize: Int64
    private let progress: @Sendable (Double) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var isCancelled = false

    // Used on the delegate queue only.
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var lastPercentage = -1
    private var failure: Error?

    init(file: URL, expectedSHA256: String?, listedSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.file = file
        self.expectedSHA256 = expectedSHA256
        self.listedSize = listedSize
        self.progress = progress
    }

    /// Downloads `url` to the file. Throws `CancellationError` when the task is cancelled; a failed
    /// or cancelled download leaves no file.
    func run(_ url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        configuration.timeoutIntervalForResource = 365 * 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.dataTask(with: URLRequest(url: url))
                let cancelNow = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    self.task = task
                    return isCancelled
                }
                task.resume()
                if cancelNow { task.cancel() }
            }
        } onCancel: {
            let task = lock.withLock { () -> URLSessionDataTask? in
                isCancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            failure = VMImageFailure("The download failed: HTTP \(status).")
            completionHandler(.cancel)
            return
        }
        expected = response.expectedContentLength > 0 ? response.expectedContentLength : listedSize
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
            handle = try FileHandle(forWritingTo: file)
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        report()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        received += Int64(data.count)
        report()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        var outcome: Error? = failure
        if outcome == nil, let error {
            let cancelled = lock.withLock { isCancelled }
            outcome = cancelled || (error as? URLError)?.code == .cancelled ? CancellationError() : error
        }
        if outcome == nil, let expectedSHA256 {
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if digest != expectedSHA256 {
                outcome = VMImageFailure("The downloaded file does not match its checksum.")
            }
        }
        if outcome != nil {
            try? FileManager.default.removeItem(at: file)
        }
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let outcome {
            continuation?.resume(throwing: outcome)
        } else {
            continuation?.resume()
        }
    }

    /// Reports the fraction received each time its whole percentage changes.
    private func report() {
        guard expected > 0 else { return }
        let fraction = min(1, Double(received) / Double(expected))
        let percentage = Int(fraction * 100)
        guard percentage != lastPercentage else { return }
        lastPercentage = percentage
        progress(fraction)
    }
}
