import Foundation

/// The files of one image folder, `<data dir>/VirtualMachines/Images/<IMAGE-ID>/`
/// (docs/virtual-machines.md › Storage).
public struct VMImageFiles: Sendable, Hashable {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// `image.yml`: the image metadata file.
    public var metadata: URL { folder.appendingPathComponent("image.yml") }
    /// `Restore.ipsw`: the IPSW, while the image downloads and installs.
    public var restoreImage: URL { folder.appendingPathComponent("Restore.ipsw") }
    /// `HardwareModel`: the hardware model the image was installed for.
    public var hardwareModel: URL { folder.appendingPathComponent("HardwareModel") }
    /// `MachineIdentifier`: the machine identifier of the image's own virtual machine.
    public var machineIdentifier: URL { folder.appendingPathComponent("MachineIdentifier") }
    /// `AuxiliaryStorage`: the auxiliary storage of the virtual machine.
    public var auxiliaryStorage: URL { folder.appendingPathComponent("AuxiliaryStorage") }
    /// `Disk.img`: the disk, a sparse file.
    public var disk: URL { folder.appendingPathComponent("Disk.img") }
}

/// Reading and writing of the image folders (docs/data-model.md › Image metadata file,
/// docs/virtual-machines.md › Storage).
public enum VMImageStore {
    /// The files of an image.
    public static func files(of id: UUID, in directory: DataDirectory) -> VMImageFiles {
        VMImageFiles(folder: directory.vmImageFolder(id))
    }

    /// Reads the image metadata file of each folder of `VirtualMachines/Images/`. A folder whose
    /// name is not a UUID, without `image.yml`, with an invalid one, or whose `id` is not its name
    /// is skipped and logged, and stays on disk (docs/data-model.md › Loading, step 2). The images
    /// are returned oldest first, without their runtime-only values.
    public static func loadAll(_ directory: DataDirectory, log: LogSink?) -> [VMImage] {
        let folder = directory.vmImagesFolder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var images: [VMImage] = []
        for name in names.sorted() {
            let files = VMImageFiles(folder: folder.appendingPathComponent(name, isDirectory: true))
            guard let id = UUID(uuidString: name) else {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: files.folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    log?.warn(.storage, "\(files.folder.path) is skipped: its name is not a UUID")
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: files.metadata.path) else {
                log?.warn(.storage, "\(files.folder.path) has no image.yml and is skipped")
                continue
            }
            do {
                let image = try ProjectFileStore.decodeYAML(VMImage.self, at: files.metadata)
                guard image.id == id else {
                    log?.warn(.storage, "\(files.metadata.path) is skipped: its id is not the name of its folder")
                    continue
                }
                images.append(image)
            } catch {
                log?.warn(.storage, "\(files.metadata.path) is skipped: \((error as? StorageError)?.reason ?? String(describing: error))")
            }
        }
        return sorted(images)
    }

    /// Oldest first: by `created`, then by `id`.
    public static func sorted(_ images: [VMImage]) -> [VMImage] {
        images.sorted { first, second in
            first.created != second.created ? first.created < second.created : first.id.uuidString < second.id.uuidString
        }
    }

    /// Writes the image metadata file of `image`, without the keys that are never stored.
    @discardableResult
    public static func write(_ image: VMImage, to directory: DataDirectory) throws -> String {
        try ProjectFileStore.writeYAML(image.stored, to: files(of: image.id, in: directory).metadata)
    }

    /// The size of the disk of an image in GB, rounded up: the size of its `Disk.img`, not the space
    /// it takes. 0 while the image has no disk (docs/virtual-machines.md › Images).
    public static func diskGB(of files: VMImageFiles) -> Int {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: files.disk.path))?[.size] as? NSNumber else { return 0 }
        return VMImageLimits.gigabytes(ofBytes: size.uint64Value)
    }

    /// The space the files of a folder take on disk, in bytes: for a sparse file, the space written
    /// so far. 0 for a folder that cannot be read.
    public static func diskBytes(of folder: URL) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
        }
        return total
    }
}
