import Foundation

/// The iOS Simulator of the device previews (docs/views.md › iOS Simulator): the engine's own
/// simulator devices, `HephaestusV2 Previews <n>`, in its device set `Runtime/simulators/`, driven
/// with `xcrun simctl --set <set>`.
enum PreviewSimulator {
    /// The prefix of the names of the engine's devices.
    static let deviceNamePrefix = "HephaestusV2 Previews "
    /// The message of a Mac without iOS runtime.
    static let noRuntimeMessage = "No iOS Simulator runtime is installed: add one in Xcode › Settings › Components."

    /// The newest available iOS runtime and the device type with the largest screen.
    struct Runtime: Sendable, Hashable {
        var identifier: String
        var version: String
        var deviceType: String
    }

    /// A device of the set.
    struct Device: Sendable, Hashable {
        var udid: String
        var name: String
        var state: String
        var runtime: String
    }

    /// A failure of a `simctl` command: its last line.
    struct Failure: Error, Sendable, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    /// Runs `xcrun simctl --set <set> <arguments>`; its standard output, or the failure with its
    /// last line.
    static func simctl(_ arguments: [String], set: URL, environment: [String: String], timeout: Duration = PreviewBuildRun.readTimeout,
                       track: (ChildProcess?) -> Void = { _ in }) async throws -> Data {
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        let output = PreviewBuildOutput { _ in }
        let (termination, data) = await PreviewBuildRun.run(["simctl", "--set", set.path] + arguments, environment: environment,
                                                            directory: set.path, timeout: timeout, output: output, track: track)
        guard termination?.isSuccess == true else {
            let last = output.lastLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            throw Failure(message: last ?? "simctl \(arguments.first ?? "") failed")
        }
        return data
    }

    /// The newest available iOS runtime and its device type whose screen has the most points; nil
    /// without iOS runtime.
    static func runtime(set: URL, environment: [String: String]) async throws -> Runtime? {
        let data = try await simctl(["list", "runtimes", "--json"], set: set, environment: environment)
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let object = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any],
              let runtimes = object["runtimes"] as? [[String: Any]] else { return nil }
        let available = runtimes.filter { runtime in
            (runtime["platform"] as? String == "iOS" || (runtime["identifier"] as? String)?.contains(".iOS-") == true)
                && runtime["isAvailable"] as? Bool != false
        }
        guard let newest = available.max(by: { compareVersions($0["version"] as? String ?? "", $1["version"] as? String ?? "") < 0 }),
              let identifier = newest["identifier"] as? String else { return nil }
        let types = newest["supportedDeviceTypes"] as? [[String: Any]] ?? []
        var best: (identifier: String, points: Double, pad: Bool)?
        for type in types {
            guard let id = type["identifier"] as? String else { continue }
            let family = type["productFamily"] as? String ?? ""
            guard family == "iPad" || family == "iPhone" else { continue }
            let points = screenPoints(bundlePath: type["bundlePath"] as? String)
            let pad = family == "iPad"
            if best == nil || (pad && !(best?.pad ?? false)) || (pad == best?.pad && points > best?.points ?? 0) {
                best = (id, points, pad)
            }
        }
        guard let deviceType = best?.identifier else { return nil }
        return Runtime(identifier: identifier, version: newest["version"] as? String ?? "", deviceType: deviceType)
    }

    /// The area in points of the main screen of a device type, from its `capabilities.plist`; 0
    /// when it cannot be read.
    static func screenPoints(bundlePath: String?) -> Double {
        guard let bundlePath else { return 0 }
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources/capabilities.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return 0 }
        let capabilities = plist["capabilities"] as? [String: Any] ?? plist
        guard let screen = capabilities["ScreenDimensionsCapability"] as? [String: Any],
              let width = (screen["main-screen-width"] as? NSNumber)?.doubleValue,
              let height = (screen["main-screen-height"] as? NSNumber)?.doubleValue,
              let scale = (screen["main-screen-scale"] as? NSNumber)?.doubleValue, scale > 0 else { return 0 }
        return width * height / (scale * scale)
    }

    /// Compares dotted versions: negative, zero or positive.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }, right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0, y = index < right.count ? right[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// The engine's devices of a runtime in the set.
    static func devices(set: URL, runtime: String, environment: [String: String]) async throws -> [Device] {
        let data = try await simctl(["list", "devices", "--json"], set: set, environment: environment)
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let object = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any],
              let byRuntime = object["devices"] as? [String: [[String: Any]]] else { return [] }
        return (byRuntime[runtime] ?? []).compactMap { device in
            guard let udid = device["udid"] as? String, let name = device["name"] as? String, name.hasPrefix(deviceNamePrefix),
                  device["isAvailable"] as? Bool != false else { return nil }
            return Device(udid: udid, name: name, state: device["state"] as? String ?? "", runtime: runtime)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Creates a device; its udid.
    static func create(name: String, runtime: Runtime, set: URL, environment: [String: String]) async throws -> String {
        let data = try await simctl(["create", name, runtime.deviceType, runtime.identifier], set: set, environment: environment)
        let udid = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else { throw Failure(message: "simctl create gave no device") }
        return udid
    }

    /// Boots a device without a window and waits until it has booted.
    static func boot(_ udid: String, set: URL, environment: [String: String]) async throws {
        do {
            _ = try await simctl(["boot", udid], set: set, environment: environment, timeout: .seconds(300))
        } catch let failure as Failure where failure.message.contains("current state: Booted") {
            // Already booted.
        }
        _ = try await simctl(["bootstatus", udid, "-b"], set: set, environment: environment, timeout: .seconds(600))
    }

    static func install(_ app: URL, on udid: String, set: URL, environment: [String: String]) async throws {
        _ = try await simctl(["install", udid, app.path], set: set, environment: environment, timeout: .seconds(300))
    }

    /// Launches the app with the port and the token of its connection.
    static func launch(_ bundleID: String, on udid: String, port: UInt16, token: String, set: URL,
                       environment: [String: String]) async throws {
        _ = try await simctl(["launch", "--terminate-running-process", udid, bundleID, "--hephaestus-port", String(port),
                              "--hephaestus-token", token], set: set, environment: environment)
    }

    static func terminate(_ bundleID: String, on udid: String, set: URL, environment: [String: String]) async {
        _ = try? await simctl(["terminate", udid, bundleID], set: set, environment: environment)
    }

    static func shutdown(_ udid: String, set: URL, environment: [String: String]) async {
        _ = try? await simctl(["shutdown", udid], set: set, environment: environment, timeout: .seconds(60))
    }

    /// Shuts every device of the set down.
    static func shutdownAll(set: URL, environment: [String: String]) async {
        guard FileManager.default.fileExists(atPath: set.path) else { return }
        _ = try? await simctl(["shutdown", "all"], set: set, environment: environment, timeout: .seconds(60))
    }

    /// The path of the iOS Simulator SDK.
    static func sdkPath(environment: [String: String], directory: URL) async -> String? {
        let output = PreviewBuildOutput { _ in }
        let (termination, data) = await PreviewBuildRun.run(["--sdk", "iphonesimulator", "--show-sdk-path"], environment: environment,
                                                            directory: directory.path, timeout: PreviewBuildRun.readTimeout,
                                                            output: output)
        guard termination?.isSuccess == true else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
