import Darwin
import Foundation

/// Reading and writing of the virtual machine folders, `<data dir>/VirtualMachines/Machines/<VM-ID>/`
/// (docs/data-model.md › VM metadata file, docs/virtual-machines.md › Storage, › Clone).
public enum VirtualMachineStore {
    /// The files a virtual machine boots from: its folder holds the hardware model, the machine
    /// identifier, the auxiliary storage and the disk under the names they have in an image's
    /// folder. Its metadata file is `metadataFile(of:in:)`, not `metadata`.
    public static func files(of id: UUID, in directory: DataDirectory) -> VMImageFiles {
        VMImageFiles(folder: directory.virtualMachineFolder(id))
    }

    /// `vm.yml`: the VM metadata file.
    public static func metadataFile(of id: UUID, in directory: DataDirectory) -> URL {
        directory.virtualMachineFolder(id).appendingPathComponent("vm.yml")
    }

    /// Reads the VM metadata file of each folder of `VirtualMachines/Machines/`. A folder whose
    /// name is not a UUID, without `vm.yml`, with an invalid one, or whose `id` is not its name is
    /// skipped and logged, and stays on disk (docs/data-model.md › Loading, step 2). The virtual
    /// machines are returned oldest first, stopped.
    public static func loadAll(_ directory: DataDirectory, log: LogSink?) -> [VirtualMachine] {
        let folder = directory.virtualMachinesFolder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var machines: [VirtualMachine] = []
        for name in names.sorted() {
            let machineFolder = folder.appendingPathComponent(name, isDirectory: true)
            guard let id = UUID(uuidString: name) else {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: machineFolder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    log?.warn(.storage, "\(machineFolder.path) is skipped: its name is not a UUID")
                }
                continue
            }
            let metadata = metadataFile(of: id, in: directory)
            guard FileManager.default.fileExists(atPath: metadata.path) else {
                log?.warn(.storage, "\(machineFolder.path) has no vm.yml and is skipped")
                continue
            }
            do {
                let machine = try ProjectFileStore.decodeYAML(VirtualMachine.self, at: metadata)
                guard machine.id == id else {
                    log?.warn(.storage, "\(metadata.path) is skipped: its id is not the name of its folder")
                    continue
                }
                machines.append(machine)
            } catch {
                log?.warn(.storage, "\(metadata.path) is skipped: \((error as? StorageError)?.reason ?? String(describing: error))")
            }
        }
        return sorted(machines)
    }

    /// Oldest first: by `created`, then by `id`.
    public static func sorted(_ machines: [VirtualMachine]) -> [VirtualMachine] {
        machines.sorted { first, second in
            first.created != second.created ? first.created < second.created : first.id.uuidString < second.id.uuidString
        }
    }

    /// Writes the VM metadata file of `machine`, without the keys that are never stored.
    @discardableResult
    public static func write(_ machine: VirtualMachine, to directory: DataDirectory) throws -> String {
        try ProjectFileStore.writeYAML(machine.stored, to: metadataFile(of: machine.id, in: directory))
    }

    /// Creates the folder of a new virtual machine (docs/virtual-machines.md › Creating, step 2):
    /// the image's hardware model, machine identifier and auxiliary storage, a clone of the
    /// image's disk, then `vm.yml`. Throws the system's error; what was written stays for the
    /// caller to delete.
    public static func create(_ machine: VirtualMachine, from image: VMImageFiles, in directory: DataDirectory) throws {
        let files = files(of: machine.id, in: directory)
        try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
        try clone(image.hardwareModel, to: files.hardwareModel)
        try clone(image.machineIdentifier, to: files.machineIdentifier)
        try clone(image.auxiliaryStorage, to: files.auxiliaryStorage)
        try clone(image.disk, to: files.disk)
        try write(machine, to: directory)
    }

    /// An APFS clone of `source` at `destination`, made with `clonefile`: the two files share their
    /// blocks until one of them changes. On a volume that cannot clone a file, the file is copied
    /// (docs/virtual-machines.md › Clone).
    public static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EXDEV else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: source.path])
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
