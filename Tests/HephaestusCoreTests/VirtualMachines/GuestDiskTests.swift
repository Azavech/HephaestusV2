import Foundation
import Testing
@testable import HephaestusCore

/// docs/virtual-machines.md › Clone: the growth of a clone, the move of its recovery container and
/// its GUID partition table, on small disks laid out as the installer of macOS lays them out.
@Suite("Guest disks")
struct GuestDiskTests {
    static let block = 512
    static let iscType = "69646961-6700-11AA-AA11-00306543ECAC"
    static let apfsType = "7C3457EF-0000-11AA-AA11-00306543ECAC"
    static let recoveryType = "52637672-7900-11AA-AA11-00306543ECAC"

    /// The bytes of a GUID as a partition entry stores it: its first three fields little-endian.
    static func guidBytes(_ text: String) -> [UInt8] {
        let hex = text.replacingOccurrences(of: "-", with: "")
        let bytes = stride(from: 0, to: 32, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
        return [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8...]
    }

    static func le(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    /// A disk of `blocks` blocks of 512 bytes with a protective MBR, both copies of a table of 128
    /// entries and three partitions: `iBootSystemContainer`, `Container` and, last, ending at the
    /// last usable block aligned on 4096 bytes, `RecoveryOSContainer` of `recoveryBlocks` blocks,
    /// whose first and last blocks hold markers and whose middle holds a pattern.
    static func makeDisk(_ url: URL, blocks: UInt64, recoveryBlocks: UInt64) throws -> (first: UInt64, last: UInt64) {
        let lastUsable = blocks - 34
        let recoveryLast = (lastUsable + 1) / 8 * 8 - 1
        let recoveryFirst = recoveryLast - recoveryBlocks + 1
        let partitions: [(String, UInt64, UInt64, String)] = [
            (iscType, 40, 2087, "iBootSystemContainer"),
            (apfsType, 2088, recoveryFirst - 1, "Container"),
            (recoveryType, recoveryFirst, recoveryLast, "RecoveryOSContainer"),
        ]
        var entries = [UInt8](repeating: 0, count: 128 * 128)
        for (index, partition) in partitions.enumerated() {
            var entry = guidBytes(partition.0) + guidBytes(UUID().uuidString) + le(partition.1, 8) + le(partition.2, 8) + le(0, 8)
            entry += partition.3.utf16.flatMap { le(UInt64($0), 2) }
            entries.replaceSubrange(index * 128..<index * 128 + entry.count, with: entry)
        }
        let entriesData = Data(entries)
        func header(current: UInt64, backup: UInt64, entriesLBA: UInt64) -> Data {
            var bytes = Array("EFI PART".utf8) + le(0x0001_0000, 4) + le(92, 4) + le(0, 4) + le(0, 4)
            bytes += le(current, 8) + le(backup, 8) + le(34, 8) + le(lastUsable, 8) + guidBytes(UUID().uuidString)
            bytes += le(entriesLBA, 8) + le(128, 4) + le(128, 4) + le(UInt64(CRC32.checksum(entriesData)), 4)
            var data = Data(bytes)
            data.setUInt32(CRC32.checksum(data), at: 16)
            return data + Data(count: block - 92)
        }
        var mbr = Data(count: block)
        mbr.replaceSubrange(446..<462, with: [0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF] + le(1, 4) + le(blocks - 1, 4))
        mbr[510] = 0x55
        mbr[511] = 0xAA

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: blocks * UInt64(block))
        try handle.write(mbr, at: 0)
        try handle.write(header(current: 1, backup: blocks - 1, entriesLBA: 2), at: UInt64(block))
        try handle.write(entriesData, at: UInt64(2 * block))
        try handle.write(entriesData, at: (blocks - 33) * UInt64(block))
        try handle.write(header(current: blocks - 1, backup: 1, entriesLBA: blocks - 33), at: (blocks - 1) * UInt64(block))
        // The recovery container: markers at both ends, a pattern in its middle, zeros elsewhere.
        try handle.write(Data("RECOVERY-FIRST".utf8), at: recoveryFirst * UInt64(block))
        try handle.write(Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) }),
                         at: (recoveryFirst + recoveryBlocks / 2) * UInt64(block))
        try handle.write(Data("RECOVERY-LAST".utf8), at: recoveryLast * UInt64(block))
        return (recoveryFirst, recoveryLast)
    }

    static func read(_ url: URL, at offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(at: offset, count: count)
    }

    @Test("The checksum is the CRC-32 of zlib")
    func checksum() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test("A grown disk has RecoveryOSContainer at its new end, with its bytes, and both copies of the table rewritten")
    func growMovesRecovery() throws {
        try withTemporaryDirectory { folder in
            let disk = folder.appendingPathComponent("Disk.img")
            let oldBlocks: UInt64 = 131_072  // 64 MiB
            let old = try Self.makeDisk(disk, blocks: oldBlocks, recoveryBlocks: 16_384)
            let length = old.last - old.first + 1
            let recovery = try Self.read(disk, at: old.first * 512, count: Int(length) * 512)
            let before = try #require(try PartitionTable.read(FileHandle(forReadingFrom: disk), diskSize: oldBlocks * 512))

            let newBlocks: UInt64 = 262_144  // 128 MiB
            #expect(try GuestDisk.grow(disk, to: newBlocks * 512) == .recoveryMoved)
            #expect(try FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? UInt64 == newBlocks * 512)

            let handle = try FileHandle(forReadingFrom: disk)
            defer { try? handle.close() }
            let table = try #require(try PartitionTable.read(handle, diskSize: newBlocks * 512))
            #expect(table.lastUsable == newBlocks - 34)
            #expect(table.backupLBA == newBlocks - 1)
            // The container and the ISC keep their place; the recovery container ends aligned on 4096 bytes.
            #expect(table.partition(0).first == 40 && table.partition(0).last == 2087)
            #expect(table.partition(1) == before.partition(1))
            let moved = table.partition(2)
            #expect(moved.name == "RecoveryOSContainer" && moved.type == UUID(uuidString: Self.recoveryType))
            #expect(moved.last == 262_103 && (moved.last + 1) % 8 == 0)
            #expect(moved.last - moved.first + 1 == length)
            #expect(try handle.read(at: moved.first * 512, count: Int(length) * 512) == recovery)

            // The backup header and entries at the new end.
            let backup = try handle.read(at: (newBlocks - 1) * 512, count: 92)
            #expect(backup.prefix(8) == Data("EFI PART".utf8))
            var unsealed = backup
            unsealed.setUInt32(0, at: 16)
            #expect(CRC32.checksum(unsealed) == backup.uint32(at: 16))
            #expect(backup.uint64(at: 24) == newBlocks - 1 && backup.uint64(at: 32) == 1 && backup.uint64(at: 72) == newBlocks - 33)
            #expect(backup.uint64(at: 48) == newBlocks - 34)
            #expect(try handle.read(at: (newBlocks - 33) * 512, count: 128 * 128) == table.entries)
            // The backup of the old size is cleared, and the protective MBR covers the whole disk.
            #expect(try handle.read(at: (oldBlocks - 33) * 512, count: 33 * 512) == Data(count: 33 * 512))
            #expect(try handle.read(at: 0, count: 512).uint32(at: 446 + 12) == UInt32(newBlocks - 1))
        }
    }

    @Test("A growth shorter than the recovery container copies it from its end, so that nothing is overwritten before it is copied")
    func growOverlapping() throws {
        try withTemporaryDirectory { folder in
            let disk = folder.appendingPathComponent("Disk.img")
            let old = try Self.makeDisk(disk, blocks: 131_072, recoveryBlocks: 16_384)
            let length = old.last - old.first + 1
            let recovery = try Self.read(disk, at: old.first * 512, count: Int(length) * 512)
            // 4 MiB more for a container of 8 MiB.
            #expect(try GuestDisk.grow(disk, to: (131_072 + 8_192) * 512) == .recoveryMoved)
            let handle = try FileHandle(forReadingFrom: disk)
            defer { try? handle.close() }
            let moved = try #require(try PartitionTable.read(handle, diskSize: (131_072 + 8_192) * 512)).partition(2)
            #expect(moved.first > old.first && moved.first < old.last)
            #expect(try handle.read(at: moved.first * 512, count: Int(length) * 512) == recovery)
        }
    }

    @Test("A disk that keeps its size is not changed; one without a GUID partition table, or without RecoveryOSContainer last, is only extended")
    func otherDisks() throws {
        try withTemporaryDirectory { folder in
            let plain = folder.appendingPathComponent("Plain.img")
            try Data("disk".utf8).write(to: plain)
            #expect(try GuestDisk.grow(plain, to: 4) == nil)
            #expect(try GuestDisk.grow(plain, to: 1 << 20) == .extendedOnly)
            #expect(try Self.read(plain, at: 0, count: 8) == Data("disk".utf8) + Data(count: 4))
            #expect(try FileManager.default.attributesOfItem(atPath: plain.path)[.size] as? UInt64 == 1 << 20)

            // A table whose entries do not match their checksum is no table.
            let broken = folder.appendingPathComponent("Broken.img")
            let old = try Self.makeDisk(broken, blocks: 131_072, recoveryBlocks: 16_384)
            let handle = try FileHandle(forUpdating: broken)
            try handle.write(Data([0xFF]), at: 2 * 512 + 2 * 128 + 56)
            try handle.close()
            #expect(try GuestDisk.grow(broken, to: 262_144 * 512) == .extendedOnly)
            #expect(try Self.read(broken, at: old.first * 512, count: 14) == Data("RECOVERY-FIRST".utf8))
        }
    }

    @Test("The command that grows the guest's container names the physical store of / and grows it to the end of the free space")
    func growCommand() {
        #expect(GuestDisk.growContainerCommand
            == #"/usr/sbin/diskutil apfs resizeContainer "$(/usr/sbin/diskutil info / | /usr/bin/awk -F': +' '/APFS Physical Store/ {print $2}')" 0"#)
        #expect(GuestDisk.growContainerTimeout == 120)
    }
}
