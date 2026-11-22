//
//  MachOInjector.swift
//  SideStore
//
//  SideStore shell: minimal Mach-O editing used to inject tweaks into sideloaded apps.
//  - adds a load command (the tweak) and an rpath to the app's main executable,
//  - rewrites a tweak's dependencies (CydiaSubstrate / jailbreak paths) so they resolve inside the app.
//  Works in place, on thin 64-bit binaries and on every 64-bit slice of fat binaries.
//  needs proper testing on device
//

import Foundation

enum MachOInjectorError: LocalizedError
{
    case notMachO(String)
    case encrypted(String)
    case noSpace(String)
    case pathTooLong(String)
    
    var errorDescription: String? {
        switch self {
        case .notMachO(let name):
            return String(format: NSLocalizedString("“%@” is not a 64-bit iOS binary.", comment: ""), name)
        case .encrypted(let name):
            return String(format: NSLocalizedString("“%@” is encrypted (App Store version). Use a decrypted .ipa to inject tweaks.", comment: ""), name)
        case .noSpace(let name):
            return String(format: NSLocalizedString("Not enough room in “%@” to add the tweak.", comment: ""), name)
        case .pathTooLong(let path):
            return String(format: NSLocalizedString("Cannot rewrite the dependency “%@” of the tweak.", comment: ""), path)
        }
    }
}

enum MachOInjector
{
    private static let MH_MAGIC_64: UInt32 = 0xfeedfacf
    private static let FAT_MAGIC: UInt32 = 0xcafebabe
    private static let FAT_MAGIC_64: UInt32 = 0xcafebabf
    
    static let LC_SEGMENT_64: UInt32 = 0x19
    static let LC_LOAD_DYLIB: UInt32 = 0xc
    static let LC_ID_DYLIB: UInt32 = 0xd
    static let LC_LOAD_WEAK_DYLIB: UInt32 = 0x80000018
    static let LC_REEXPORT_DYLIB: UInt32 = 0x8000001f
    static let LC_LAZY_LOAD_DYLIB: UInt32 = 0x20
    static let LC_LOAD_UPWARD_DYLIB: UInt32 = 0x80000023
    static let LC_RPATH: UInt32 = 0x8000001c
    static let LC_ENCRYPTION_INFO_64: UInt32 = 0x2c
    
    private static let dependencyCommands: Set<UInt32> = [LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB]
    
    // MARK: Byte helpers
    
    private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
    private static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
    private static func readBE64(_ data: Data, _ offset: Int) -> UInt64 {
        data.withUnsafeBytes { raw in
            UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
    private static func writeLE32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            data.replaceSubrange(offset..<offset + 4, with: bytes)
        }
    }
    private static func readCString(_ data: Data, _ offset: Int, maxLength: Int) -> String {
        let end = min(offset + maxLength, data.count)
        guard offset < end else { return "" }
        let slice = data[offset..<end]
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
    
    /// Offsets of every 64-bit Mach-O slice in the file.
    private static func sliceOffsets(_ data: Data, name: String) throws -> [Int] {
        guard data.count >= 32 else { throw MachOInjectorError.notMachO(name) }
        let magicBE = readBE32(data, 0)
        if magicBE == FAT_MAGIC || magicBE == FAT_MAGIC_64 {
            let count = Int(readBE32(data, 4))
            var offsets: [Int] = []
            for index in 0..<count {
                if magicBE == FAT_MAGIC {
                    let base = 8 + index * 20
                    offsets.append(Int(readBE32(data, base + 8)))
                } else {
                    let base = 8 + index * 32
                    offsets.append(Int(readBE64(data, base + 8)))
                }
            }
            let slices = offsets.filter { $0 + 32 <= data.count && readLE32(data, $0) == MH_MAGIC_64 }
            guard !slices.isEmpty else { throw MachOInjectorError.notMachO(name) }
            return slices
        }
        guard readLE32(data, 0) == MH_MAGIC_64 else { throw MachOInjectorError.notMachO(name) }
        return [0]
    }
    
    private struct LoadCommand {
        let offset: Int     // absolute offset in the file
        let cmd: UInt32
        let size: Int
    }
    
    private static func loadCommands(_ data: Data, slice: Int) -> [LoadCommand] {
        let ncmds = Int(readLE32(data, slice + 16))
        var commands: [LoadCommand] = []
        var cursor = slice + 32
        for _ in 0..<ncmds {
            guard cursor + 8 <= data.count else { break }
            let cmd = readLE32(data, cursor)
            let size = Int(readLE32(data, cursor + 4))
            guard size >= 8 else { break }
            commands.append(LoadCommand(offset: cursor, cmd: cmd, size: size))
            cursor += size
        }
        return commands
    }
    
    /// Bytes available between the end of the load commands and the first section's data.
    private static func freeSpace(_ data: Data, slice: Int) -> Int {
        let sizeofcmds = Int(readLE32(data, slice + 20))
        let commandsEnd = 32 + sizeofcmds
        var firstData = Int.max
        for command in loadCommands(data, slice: slice) where command.cmd == LC_SEGMENT_64 {
            let nsects = Int(readLE32(data, command.offset + 64))
            for index in 0..<nsects {
                let section = command.offset + 72 + index * 80
                guard section + 80 <= data.count else { break }
                let offset = Int(readLE32(data, section + 48))
                if offset > 0 { firstData = min(firstData, offset) }
            }
        }
        guard firstData != Int.max else { return 0 }
        return firstData - commandsEnd
    }
    
    private static func isEncrypted(_ data: Data, slice: Int) -> Bool {
        loadCommands(data, slice: slice).contains { command in
            command.cmd == LC_ENCRYPTION_INFO_64 && readLE32(data, command.offset + 16) != 0
        }
    }
    
    private static func appendCommand(_ data: inout Data, slice: Int, command: Data, name: String) throws {
        guard freeSpace(data, slice: slice) >= command.count else { throw MachOInjectorError.noSpace(name) }
        let ncmds = readLE32(data, slice + 16)
        let sizeofcmds = readLE32(data, slice + 20)
        let insertAt = slice + 32 + Int(sizeofcmds)
        data.replaceSubrange(insertAt..<insertAt + command.count, with: command)
        writeLE32(&data, slice + 16, ncmds + 1)
        writeLE32(&data, slice + 20, sizeofcmds + UInt32(command.count))
    }
    
    private static func paddedString(_ string: String, headerSize: Int) -> (bytes: Data, cmdsize: Int) {
        var bytes = Data(string.utf8)
        bytes.append(0)
        var cmdsize = headerSize + bytes.count
        cmdsize = (cmdsize + 7) & ~7
        bytes.append(contentsOf: [UInt8](repeating: 0, count: cmdsize - headerSize - bytes.count))
        return (bytes, cmdsize)
    }
    
    // MARK: Public API
    
    /// Paths of the libraries a binary links against (first 64-bit slice).
    static func dependencies(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        guard let slice = try sliceOffsets(data, name: url.lastPathComponent).first else { return [] }
        return loadCommands(data, slice: slice)
            .filter { dependencyCommands.contains($0.cmd) }
            .map { command in
                let nameOffset = Int(readLE32(data, command.offset + 8))
                return readCString(data, command.offset + nameOffset, maxLength: command.size - nameOffset)
            }
    }
    
    static func ensureNotEncrypted(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        for slice in try sliceOffsets(data, name: url.lastPathComponent) where isEncrypted(data, slice: slice) {
            throw MachOInjectorError.encrypted(url.lastPathComponent)
        }
    }
    
    /// Adds `LC_LOAD_WEAK_DYLIB <path>` to every slice (skipped when already present).
    static func addWeakDylib(_ path: String, to url: URL) throws {
        var data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        let (stringBytes, cmdsize) = paddedString(path, headerSize: 24)
        var command = Data()
        for value in [LC_LOAD_WEAK_DYLIB, UInt32(cmdsize), 24, 2, 0x10000, 0x10000] {
            withUnsafeBytes(of: value.littleEndian) { command.append(contentsOf: $0) }
        }
        command.append(stringBytes)
        
        for slice in try sliceOffsets(data, name: name) {
            if isEncrypted(data, slice: slice) { throw MachOInjectorError.encrypted(name) }
            let existing = loadCommands(data, slice: slice).contains { cmd in
                guard dependencyCommands.contains(cmd.cmd) else { return false }
                let nameOffset = Int(readLE32(data, cmd.offset + 8))
                return readCString(data, cmd.offset + nameOffset, maxLength: cmd.size - nameOffset) == path
            }
            if existing { continue }
            try appendCommand(&data, slice: slice, command: command, name: name)
        }
        try data.write(to: url, options: .atomic)
    }
    
    /// Adds `LC_RPATH <path>` to every slice (skipped when already present).
    static func addRPath(_ path: String, to url: URL) throws {
        var data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        let (stringBytes, cmdsize) = paddedString(path, headerSize: 12)
        var command = Data()
        for value in [LC_RPATH, UInt32(cmdsize), 12] {
            withUnsafeBytes(of: value.littleEndian) { command.append(contentsOf: $0) }
        }
        command.append(stringBytes)
        
        for slice in try sliceOffsets(data, name: name) {
            let existing = loadCommands(data, slice: slice).contains { cmd in
                guard cmd.cmd == LC_RPATH else { return false }
                let pathOffset = Int(readLE32(data, cmd.offset + 8))
                return readCString(data, cmd.offset + pathOffset, maxLength: cmd.size - pathOffset) == path
            }
            if existing { continue }
            try appendCommand(&data, slice: slice, command: command, name: name)
        }
        try data.write(to: url, options: .atomic)
    }
    
    /// Rewrites dependencies in place. `transform` returns the replacement path (nil = keep)
    /// and whether the dependency should become weak (optional at load time).
    static func rewriteDependencies(of url: URL, transform: (String) -> (newPath: String?, makeWeak: Bool)) throws {
        var data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        for slice in try sliceOffsets(data, name: name) {
            for command in loadCommands(data, slice: slice) where dependencyCommands.contains(command.cmd) {
                let nameOffset = Int(readLE32(data, command.offset + 8))
                let available = command.size - nameOffset
                let current = readCString(data, command.offset + nameOffset, maxLength: available)
                let (newPath, makeWeak) = transform(current)
                
                if let newPath, newPath != current {
                    var bytes = Data(newPath.utf8)
                    guard bytes.count + 1 <= available else { throw MachOInjectorError.pathTooLong(current) }
                    bytes.append(contentsOf: [UInt8](repeating: 0, count: available - bytes.count))
                    let start = command.offset + nameOffset
                    data.replaceSubrange(start..<start + available, with: bytes)
                }
                if makeWeak && command.cmd == LC_LOAD_DYLIB {
                    writeLE32(&data, command.offset, LC_LOAD_WEAK_DYLIB)
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }
}
