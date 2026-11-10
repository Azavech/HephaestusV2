import Foundation

/// The disk of a macOS guest (docs/virtual-machines.md › Clone, › Starting): the growth of a
/// virtual machine's clone on this Mac, which moves the recovery container to the end of the disk
/// and rewrites the GUID partition table, and the command that grows the guest's APFS container
/// over the free space at its first start.
public enum GuestDisk {
    /// How a disk grew.
    public enum Growth: Sendable, Hashable {
        /// `RecoveryOSContainer` moved to the end of the disk, and the partition table rewritten:
        /// the free space follows the guest's container.
        case recoveryMoved
        /// The file was only extended: the disk has no GUID partition table, or its last partition
        /// is not `RecoveryOSContainer`.
        case extendedOnly
    }

    /// The command the agent runs as root at the first start of a virtual machine whose disk grew:
    /// the guest's APFS container grows over the free space that follows it.
    public static let growContainerCommand =
        #"/usr/sbin/diskutil apfs resizeContainer "$(/usr/sbin/diskutil info / | /usr/bin/awk -F': +' '/APFS Physical Store/ {print $2}')" 0"#
    /// The timeout of that command, in seconds.
    public static let growContainerTimeout = 120

    /// The name of the partition of macOS Recovery that the installer writes last.
    static let recoveryName = "RecoveryOSContainer"
    /// The partition type of an APFS recovery container, `Apple_APFS_Recovery`.
    static let recoveryType = UUID(uuidString: "52637672-7900-11AA-AA11-00306543ECAC")!
    /// The bytes copied at a time; a block of zeros of this size is not written past the old end.
    static let copyChunk = 1 << 20
    /// The alignment of the end of the moved partition, in bytes.
    static let alignment = 4096

    /// Grows `disk` to `bytes` (docs/virtual-machines.md › Clone): extends the file, then moves
    /// `RecoveryOSContainer` to the end and rewrites both copies of the partition table and the
    /// protective MBR. Returns nil, changing nothing, when the disk already has `bytes` or more.
    /// Throws the system's error of a read or a write.
    public static func grow(_ disk: URL, to bytes: UInt64) throws -> Growth? {
        let handle = try FileHandle(forUpdating: disk)
        defer { try? handle.close() }
        let oldSize = try handle.seekToEnd()
        guard bytes > oldSize else { return nil }
        let table = try PartitionTable.read(handle, diskSize: oldSize)
        try handle.truncate(atOffset: bytes)
        guard let table, let plan = table.move(toDiskSize: bytes) else { return .extendedOnly }
        try plan.apply(handle, oldDiskSize: oldSize)
        return .recoveryMoved
    }
}

/// The GUID partition table of a disk, read from its primary copy.
struct PartitionTable {
    /// The size of a block: 512 or 4096 bytes.
    let blockSize: Int
    /// The primary header, its first `headerSize` bytes.
    var header: Data
    /// The partition entries.
    var entries: Data
    let entryCount: Int
    let entrySize: Int

    var lastUsable: UInt64 { header.uint64(at: 48) }
    var backupLBA: UInt64 { header.uint64(at: 32) }
    var entriesLBA: UInt64 { header.uint64(at: 72) }
    /// The blocks of the entries.
    var entryBlocks: UInt64 { UInt64((entryCount * entrySize + blockSize - 1) / blockSize) }

    /// The table of a disk of `diskSize` bytes; nil without a valid table: no signature, a header
    /// or entries whose checksum differs, or sizes out of bounds.
    static func read(_ handle: FileHandle, diskSize: UInt64) throws -> PartitionTable? {
        for blockSize in [512, 4096] where UInt64(blockSize * 2) <= diskSize {
            let block = try handle.read(at: UInt64(blockSize), count: blockSize)
            guard block.count == blockSize, block.prefix(8) == Data("EFI PART".utf8) else { continue }
            let headerSize = Int(block.uint32(at: 12))
            guard (92...blockSize).contains(headerSize) else { return nil }
            var header = Data(block.prefix(headerSize))
            let storedCRC = header.uint32(at: 16)
            header.setUInt32(0, at: 16)
            guard CRC32.checksum(header) == storedCRC else { return nil }
            header.setUInt32(storedCRC, at: 16)
            let entryCount = Int(header.uint32(at: 80))
            let entrySize = Int(header.uint32(at: 84))
            guard (1...1024).contains(entryCount), entrySize >= 128, entrySize <= 1024 else { return nil }
            let entries = try handle.read(at: header.uint64(at: 72) * UInt64(blockSize), count: entryCount * entrySize)
            guard entries.count == entryCount * entrySize, CRC32.checksum(entries) == header.uint32(at: 88) else { return nil }
            return PartitionTable(blockSize: blockSize, header: header, entries: entries, entryCount: entryCount, entrySize: entrySize)
        }
        return nil
    }

    /// The partition `index`: its type, nil for an unused entry, its first and last blocks and its
    /// name.
    func partition(_ index: Int) -> (type: UUID?, first: UInt64, last: UInt64, name: String) {
        let entry = [UInt8](entries.subdata(in: index * entrySize..<(index + 1) * entrySize))
        // The type GUID is stored with its first three fields little-endian.
        let order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
        let type = entry[0..<16].allSatisfy { $0 == 0 } ? nil : UUID(uuidString: order.map { String(format: "%02X", entry[$0]) }
            .enumerated().map { [4, 6, 8, 10].contains($0.offset) ? "-" + $0.element : $0.element }.joined())
        var units: [UInt16] = []
        for offset in stride(from: 56, to: min(128, entrySize) - 1, by: 2) {
            let unit = UInt16(entry[offset]) | UInt16(entry[offset + 1]) << 8
            guard unit != 0 else { break }
            units.append(unit)
        }
        let data = Data(entry)
        return (type, data.uint64(at: 32), data.uint64(at: 40), String(decoding: units, as: UTF16.self))
    }

    /// The move of `RecoveryOSContainer` to the end of a disk of `diskSize` bytes; nil when the
    /// last partition is not that container, or the disk does not leave room to move it.
    func move(toDiskSize diskSize: UInt64) -> RecoveryMove? {
        let block = UInt64(blockSize)
        let used = (0..<entryCount).map { ($0, partition($0)) }.filter { $0.1.type != nil }
        guard let (index, last) = used.max(by: { $0.1.first < $1.1.first }),
              last.type == GuestDisk.recoveryType || last.name == GuestDisk.recoveryName,
              last.first <= last.last, last.last <= lastUsable, backupLBA > lastUsable else { return nil }
        let blocks = diskSize / block
        let backupHeader = blocks - 1
        let backupEntries = backupHeader - entryBlocks
        let newLastUsable = backupEntries - 1
        let aligned = max(1, UInt64(GuestDisk.alignment) / block)
        let newLast = (newLastUsable + 1) / aligned * aligned - 1
        let length = last.last - last.first + 1
        guard newLast >= length, newLast - length + 1 > last.first else { return nil }
        return RecoveryMove(table: self, index: index, first: last.first, length: length, newFirst: newLast - length + 1,
                            newLastUsable: newLastUsable, backupEntries: backupEntries, backupHeader: backupHeader)
    }
}

/// The move of the recovery container and the partition table that follows it.
struct RecoveryMove {
    let table: PartitionTable
    let index: Int
    /// The first block and the length of the partition, in blocks.
    let first: UInt64
    let length: UInt64
    let newFirst: UInt64
    let newLastUsable: UInt64
    let backupEntries: UInt64
    let backupHeader: UInt64

    /// Clears the backup table of the old size, copies the partition's bytes, from its end to its
    /// start, then writes both copies of the table and the protective MBR.
    func apply(_ handle: FileHandle, oldDiskSize: UInt64) throws {
        let block = UInt64(table.blockSize)
        let oldBackupFirst = table.backupLBA - table.entryBlocks
        if oldBackupFirst > table.lastUsable {
            try handle.write(Data(count: Int((table.entryBlocks + 1) * block)), at: oldBackupFirst * block)
        }

        let source = first * block
        let destination = newFirst * block
        var end = length * block
        let chunk = UInt64(GuestDisk.copyChunk)
        while end > 0 {
            let start = end > chunk ? end - chunk : 0
            let data = try handle.read(at: source + start, count: Int(end - start))
            // Past the old end the file reads as zeros: a block of zeros takes no room there.
            if destination + start < oldDiskSize || !Self.isZero(data) {
                try handle.write(data, at: destination + start)
            }
            end = start
        }

        var entries = table.entries
        let entryOffset = index * table.entrySize
        entries.setUInt64(newFirst, at: entryOffset + 32)
        entries.setUInt64(newFirst + length - 1, at: entryOffset + 40)
        let entriesCRC = CRC32.checksum(entries)

        var primary = table.header
        primary.setUInt64(backupHeader, at: 32)
        primary.setUInt64(newLastUsable, at: 48)
        primary.setUInt32(entriesCRC, at: 88)
        var backup = primary
        backup.setUInt64(backupHeader, at: 24)
        backup.setUInt64(1, at: 32)
        backup.setUInt64(backupEntries, at: 72)

        try handle.write(entries, at: table.entriesLBA * block)
        try handle.write(Self.sealed(primary, blockSize: table.blockSize), at: block)
        try handle.write(entries, at: backupEntries * block)
        try handle.write(Self.sealed(backup, blockSize: table.blockSize), at: backupHeader * block)

        // The protective MBR covers the whole disk, at most 2³² − 1 blocks.
        var mbr = try handle.read(at: 0, count: 512)
        if mbr.count == 512, mbr[510] == 0x55, mbr[511] == 0xAA, mbr[446 + 4] == 0xEE {
            mbr.setUInt32(UInt32(min(backupHeader, UInt64(UInt32.max))), at: 446 + 12)
            try handle.write(mbr, at: 0)
        }
    }

    /// Whether every byte of `data` is zero, read 8 bytes at a time.
    static func isZero(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            let words = raw.count / 8
            for index in 0..<words where base.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self) != 0 {
                return false
            }
            return raw[(words * 8)...].allSatisfy { $0 == 0 }
        }
    }

    /// A header with its checksum, padded with zeros to a block.
    static func sealed(_ header: Data, blockSize: Int) -> Data {
        var header = header
        header.setUInt32(0, at: 16)
        header.setUInt32(CRC32.checksum(header), at: 16)
        return header + Data(count: blockSize - header.count)
    }
}

/// The CRC-32 of the GUID partition table, the one of zlib.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension FileHandle {
    /// Up to `count` bytes at `offset`; fewer at the end of the file.
    func read(at offset: UInt64, count: Int) throws -> Data {
        try seek(toOffset: offset)
        return try read(upToCount: count) ?? Data()
    }

    func write(_ data: Data, at offset: UInt64) throws {
        try seek(toOffset: offset)
        try write(contentsOf: data)
    }
}

extension Data {
    /// The little-endian integer at `offset` from the start of the data.
    func uint32(at offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func uint64(at offset: Int) -> UInt64 {
        withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }

    mutating func setUInt32(_ value: UInt32, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(startIndex + offset..<startIndex + offset + 4, with: $0) }
    }

    mutating func setUInt64(_ value: UInt64, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(startIndex + offset..<startIndex + offset + 8, with: $0) }
    }
}
