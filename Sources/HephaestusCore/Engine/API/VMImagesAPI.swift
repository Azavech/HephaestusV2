import Foundation

// docs/engine-api.md › Virtual machine images.

/// One macOS version of the list of ipsw.me (docs/engine-api.md › MacOSVersion,
/// docs/virtual-machines.md › macOS versions).
public struct MacOSVersion: Codable, Sendable, Hashable, Identifiable {
    /// The macOS version, for example `27.2.1`.
    public var version: String
    /// The macOS build, for example `26B131`; it names the version in `vmImages.add`.
    public var build: String
    /// The Apple URL of the version's IPSW.
    public var url: String
    /// The size of the IPSW in bytes; 0 when ipsw.me gives none.
    public var sizeBytes: Int
    /// The SHA-256 of the IPSW, 64 lowercase hexadecimal digits; nil when ipsw.me gives none.
    public var sha256: String?

    public var id: String { build }

    public init(version: String, build: String, url: String, sizeBytes: Int = 0, sha256: String? = nil) {
        self.version = version
        self.build = build
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    /// `<version> (<build>)`, the form of the macOS column and of the Version pop-up
    /// (docs/ui.md › Virtual Machines).
    public static func title(version: String, build: String) -> String {
        "\(version) (\(build))"
    }
}

/// `vmImages.list`: the images, oldest first. Actors: user.
public enum VMImagesList: EngineMethod {
    public static let name = "vmImages.list"
    public typealias Params = Empty
    public typealias Result = [VMImage]
}

/// `vmImages.versions`: the macOS versions for virtual machines that ipsw.me gives, newest first.
/// Actors: user.
public enum VMImagesVersions: EngineMethod {
    public static let name = "vmImages.versions"
    public typealias Params = Empty
    public typealias Result = [MacOSVersion]
}

/// `vmImages.add`: creates an image of a macOS version, then downloads its IPSW and installs macOS
/// in the background. Actors: user.
public enum VMImagesAdd: EngineMethod {
    public static let name = "vmImages.add"
    public struct Params: Codable, Sendable, Hashable {
        /// The `build` of a version of the list of `vmImages.versions`.
        public var build: String

        public init(build: String) {
            self.build = build
        }
    }
    public typealias Result = VMImage
}

/// `vmImages.delete`: ends the image's download or install, stops its setup virtual machine and
/// deletes its folder. Actors: user.
public enum VMImagesDelete: EngineMethod {
    public static let name = "vmImages.delete"
    public struct Params: Codable, Sendable, Hashable {
        public var imageID: UUID

        public init(imageID: UUID) {
            self.imageID = imageID
        }
    }
    public typealias Result = Empty
}
