import CryptoKit
import Foundation

/// The app of an iOS preview host (docs/views.md › Swift package, Xcode project):
/// `HephaestusPreviewApps/<target>/HephaestusPreviewHost.app` in the build folder, with the host as its executable,
/// the resources of the build and an `Info.plist` with the identifier of the preview host, the
/// iPhone and the iPad as device families, and no storyboard or scene of the application.
enum PreviewIOSApp {
    static let executableName = "HephaestusPreviewHost"
    /// The folder of the apps in the build folder.
    static let appsFolder = "HephaestusPreviewApps"

    /// The identifier of the app of a target's host: one per build folder and target, so that the
    /// hosts of two targets can run at the same time.
    static func bundleID(buildFolder: URL, target: String) -> String {
        let digest = SHA256.hash(data: Data((buildFolder.standardizedFileURL.path + "\n" + target).utf8))
        return "ca.azavech.hephaestusv2.preview-host-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `HephaestusPreviewApps/<target>/HephaestusPreviewHost.app` in the build folder.
    static func appFolder(buildFolder: URL, target: String) -> URL {
        let name = target.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return buildFolder.appendingPathComponent(appsFolder).appendingPathComponent(name).appendingPathComponent("\(executableName).app")
    }

    /// The keys of an application's `Info.plist` that would start its own interface.
    static let removedKeys = [
        "UIMainStoryboardFile", "UIMainStoryboardFile~ipad", "UIMainStoryboardFile~iphone", "NSMainStoryboardFile",
        "UILaunchStoryboardName", "UILaunchStoryboardName~ipad", "UILaunchStoryboardName~iphone", "UILaunchScreen~ipad",
        "UILaunchScreen~iphone", "UIApplicationSceneManifest", "UIRequiredDeviceCapabilities", "UISupportedInterfaceOrientations~ipad",
    ]

    /// The `Info.plist` of the app: an application's with its interface left out, or a new one.
    static func infoPlist(base: [String: Any]?, bundleID: String) -> [String: Any] {
        var plist = base ?? [
            "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "MinimumOSVersion": "15.0",
        ]
        for key in removedKeys { plist.removeValue(forKey: key) }
        plist["CFBundleIdentifier"] = bundleID
        plist["CFBundleExecutable"] = executableName
        plist["CFBundleName"] = executableName
        plist["CFBundlePackageType"] = "APPL"
        plist["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        plist["UIDeviceFamily"] = [1, 2]
        plist["UILaunchScreen"] = [String: Any]()
        plist["UIRequiresFullScreen"] = true
        plist["UIApplicationSceneManifest"] = ["UIApplicationSupportsMultipleScenes": false]
        plist["UISupportedInterfaceOrientations"] = [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ]
        return plist
    }

    /// Makes the app: a copy of `base`, an application that Xcode built, or an empty folder; the
    /// host executable; the resource bundles; the `Info.plist`.
    static func make(at app: URL, executable: URL, base: URL?, resources: [URL], bundleID: String) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: app.path) { try manager.removeItem(at: app) }
        try manager.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        var basePlist: [String: Any]?
        if let base {
            // On APFS the copy is a clone.
            try manager.copyItem(at: base, to: app)
            if let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")) {
                basePlist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            }
            try? manager.removeItem(at: app.appendingPathComponent("_CodeSignature"))
            try? manager.removeItem(at: app.appendingPathComponent("embedded.mobileprovision"))
        } else {
            try manager.createDirectory(at: app, withIntermediateDirectories: true)
        }
        let destination = app.appendingPathComponent(executableName)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: executable, to: destination)
        for resource in resources {
            let target = app.appendingPathComponent(resource.lastPathComponent)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: resource, to: target)
        }
        let plist = infoPlist(base: basePlist, bundleID: bundleID)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
    }
}
