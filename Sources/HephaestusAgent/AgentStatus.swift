import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// The status object of the hello and of the method `status` (docs/virtual-machines.md › Messages).
enum AgentStatus {
    static func current() -> [String: Any] {
        [
            "version": AgentInfo.version,
            "sip": sipState(),
            "user": NSUserName(),
            "osVersion": osVersion(),
            "osBuild": osBuild(),
            "accessibility": AXIsProcessTrusted(),
            "screenRecording": CGPreflightScreenCaptureAccess(),
        ]
    }

    /// `disabled`, `enabled` or `unknown`, read from the output of `/usr/bin/csrutil status`.
    static func sipState() -> String {
        guard let output = run("/usr/bin/csrutil", ["status"]) else { return "unknown" }
        return sipState(fromOutput: output)
    }

    /// The state named by the first line of the output: `System Integrity Protection status: disabled.`
    static func sipState(fromOutput output: String) -> String {
        guard let line = output.split(whereSeparator: \.isNewline).first,
              let status = line.range(of: "status:", options: .caseInsensitive) else { return "unknown" }
        let word = line[status.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        if word.hasPrefix("disabled") { return "disabled" }
        if word.hasPrefix("enabled") { return "enabled" }
        return "unknown"
    }

    /// The macOS version: `27.2.1`, or `27.2` without a patch number.
    static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// The macOS build, for example `26B131` (`kern.osversion`).
    static func osBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// The standard output of a tool that ends within 10 seconds; nil when it cannot run.
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let ended = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global().async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            ended.signal()
        }
        if ended.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}
