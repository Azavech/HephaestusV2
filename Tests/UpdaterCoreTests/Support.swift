import Foundation
@testable import UpdaterCore

/// A temporary folder removed at deinit.
final class TemporaryFolder: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdaterCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // A test may have made a folder read-only.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ component: String) -> URL {
        url.appendingPathComponent(component)
    }
}

/// Answers of the stubbed HTTP server, by absolute URL. No request leaves the process.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    static func set(_ url: String, _ answer: Answer) {
        lock.lock()
        answers[url] = answer
        lock.unlock()
    }

    static func set(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        set(url, .response(status: status, headers: headers, body: body))
    }

    static func requests(to url: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests[url] ?? []
    }

    /// An ephemeral session whose requests are all answered by the stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.requests[key, default: []].append(request)
        let answer = Self.answers[key] ?? .response(status: 599, headers: [:], body: Data())
        Self.lock.unlock()
        switch answer {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers.merging(["Content-Length": String(body.count)]) { a, _ in a })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Builds small app bundles signed ad hoc, and their zips.
enum TestBundle {
    /// `<folder>/<name>`, a bundle whose executable is a copy of `/usr/bin/true`.
    @discardableResult
    static func make(in folder: URL, name: String = "HephaestusV2.app", identifier: String = "ca.azavech.hephaestusv2",
                     version: String = "0.5.0", build: String = "61", sign: Bool = true) throws -> URL {
        let app = folder.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("HephaestusV2").path)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "HephaestusV2",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign {
            try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        }
        return app
    }

    /// Zips `item` as the release workflow does.
    static func zip(_ item: URL, to zip: URL) throws {
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", item.path, zip.path])
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError("\(executable) exited with status \(process.terminationStatus)")
        }
    }

    /// A manifest describing `zip`.
    static func manifest(for zip: URL, version: String = "0.5.0", build: Int = 61) throws -> ReleaseManifest {
        let size = try (FileManager.default.attributesOfItem(atPath: zip.path)[.size] as! NSNumber).intValue
        return ReleaseManifest(version: version, build: build, sha256: try UpdateDownloader.sha256Hex(of: zip), size: size,
                               minimumSystemVersion: "26.0", published: Date(timeIntervalSince1970: 1_793_000_000), notes: "- fix: x\n")
    }
}

/// Waits until `condition` holds, at most `seconds`.
func eventually(_ seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
