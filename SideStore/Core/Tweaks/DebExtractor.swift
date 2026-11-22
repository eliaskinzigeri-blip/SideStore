//
//  DebExtractor.swift
//  SideStore
//
//  SideStore shell: pulls the tweak libraries (.dylib) out of a jailbreak package (.deb).
//  A .deb is an "ar" archive holding data.tar.<gz|xz|lzma|zst|bz2>; the tweak itself lives in
//  Library/MobileSubstrate/DynamicLibraries (rootful) or var/jb/... / usr/lib/TweakInject (rootless).
//  Supported compressions: none, gzip, xz (Apple's Compression), zstd and bzip2 (bundled C decoders).
//  needs proper testing on device
//

import Foundation
import Compression

enum DebExtractorError: LocalizedError
{
    case notADeb
    case noData
    case unsupportedCompression(String)
    case decompressionFailed
    case noTweakInside

    var errorDescription: String? {
        switch self {
        case .notADeb:
            return NSLocalizedString("This file is not a valid .deb package.", comment: "")
        case .noData:
            return NSLocalizedString("The .deb package has no content.", comment: "")
        case .unsupportedCompression(let name):
            return String(format: NSLocalizedString("This .deb uses a compression SideStore cannot read (%@). Extract the .dylib on a computer and add it instead.", comment: ""), name)
        case .decompressionFailed:
            return NSLocalizedString("The .deb package could not be decompressed.", comment: "")
        case .noTweakInside:
            return NSLocalizedString("No tweak library (.dylib) or framework was found in this .deb.", comment: "")
        }
    }
}

enum DebExtractor
{
    /// Returns (file name, contents) of every tweak library in the package.
    static func extractTweaks(from debURL: URL) throws -> [(name: String, data: Data)] {
        try extractPackage(from: debURL).tweaks
    }
    
    /// Tweak libraries, plus the frameworks the package ships for them (e.g. SwiftProtobuf.framework in
    /// Library/Frameworks): each framework file is given as "Name.framework/…" so it can be placed next to
    /// the tweak or in the app's Frameworks folder, where the tweak's @rpath finds it.
    static func extractPackage(from debURL: URL) throws -> (tweaks: [(name: String, data: Data)], frameworkFiles: [(path: String, data: Data)]) {
        let deb = try Data(contentsOf: debURL)
        let (memberName, member) = try dataMember(of: deb)
        let tar = try decompress(member, name: memberName)
        let files = try tarFiles(tar)

        let dylibs = files.filter { $0.path.hasSuffix(".dylib") && !$0.path.contains(".framework/") }
        let tweakDylibs = dylibs.filter {
            $0.path.contains("/DynamicLibraries/") || $0.path.contains("/TweakInject/")
        }
        let chosen = tweakDylibs.isEmpty ? dylibs : tweakDylibs
        
        var frameworkFiles: [(path: String, data: Data)] = []
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard let index = components.firstIndex(where: { $0.hasSuffix(".framework") }) else { continue }
            let frameworkName = components[index].lowercased()
            // CydiaSubstrate / ElleKit come from LiveContainer, never from the package
            if frameworkName.contains("substrate") || frameworkName.contains("ellekit") { continue }
            frameworkFiles.append((components[index...].joined(separator: "/"), file.data))
        }
        // a runtime package (e.g. the Orion runtime other tweaks need) may hold only frameworks
        guard !chosen.isEmpty || !frameworkFiles.isEmpty else { throw DebExtractorError.noTweakInside }
        
        return (chosen.map { (($0.path as NSString).lastPathComponent, $0.data) }, frameworkFiles)
    }
    
    /// Writes framework files returned by `extractPackage` under `folderURL`. Returns the framework folders.
    @discardableResult
    static func writeFrameworkFiles(_ files: [(path: String, data: Data)], into folderURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []
        for (path, data) in files {
            let destination = folderURL.appendingPathComponent(path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            if let root = path.split(separator: "/").first.map(String.init) {
                let rootURL = folderURL.appendingPathComponent(root, isDirectory: true)
                if !roots.contains(rootURL) { roots.append(rootURL) }
            }
        }
        return roots
    }

    /// Main binary of each framework folder written by `writeFrameworkFiles` (Name.framework/Name).
    static func frameworkBinaries(_ roots: [URL]) -> [URL] {
        roots.compactMap { root in
            let binary = root.appendingPathComponent(root.deletingPathExtension().lastPathComponent)
            return FileManager.default.fileExists(atPath: binary.path) ? binary : nil
        }
    }
    
    /// A framework installed by a jailbreak (/Library/Frameworks/Orion.framework/Orion,
    /// /var/jb/Library/Frameworks/...) resolved through @rpath instead, so a copy placed next to the
    /// tweak or in the app's Frameworks folder is found. Nil when `path` is not such a framework.
    static func jailbreakFrameworkRPath(_ path: String) -> String? {
        guard path.hasPrefix("/Library/Frameworks/") || path.hasPrefix("/var/jb/Library/Frameworks/") || path.hasPrefix("/usr/local/Frameworks/") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".framework") }) else { return nil }
        return "@rpath/" + components[index...].joined(separator: "/")
    }

    // MARK: ar

    private static func dataMember(of deb: Data) throws -> (String, Data) {
        guard deb.count > 8, String(decoding: deb.prefix(8), as: UTF8.self) == "!<arch>\n" else {
            throw DebExtractorError.notADeb
        }
        var cursor = 8
        while cursor + 60 <= deb.count {
            let header = deb[cursor..<cursor + 60]
            let name = String(decoding: header.prefix(16), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let sizeText = String(decoding: header.dropFirst(48).prefix(10), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText) else { throw DebExtractorError.notADeb }
            let start = cursor + 60
            let end = min(start + size, deb.count)
            if name.hasPrefix("data.tar") {
                return (name, Data(deb[start..<end]))
            }
            cursor = end + (size % 2)   // members are 2-byte aligned
        }
        throw DebExtractorError.noData
    }

    // MARK: Decompression

    private static func decompress(_ data: Data, name: String) throws -> Data {
        if name == "data.tar" { return data }
        if name.hasSuffix(".gz") { return try gunzip(data) }
        if name.hasSuffix(".xz") || name.hasSuffix(".lzma") {
            // Apple's LZMA decoder reads the .xz container; a legacy .lzma file will fail here.
            return try stream(data, algorithm: COMPRESSION_LZMA)
        }
        if name.hasSuffix(".zst") || name.hasSuffix(".zstd") {
            return try bundledDecoder(data, decoder: sc_zstd_decompress)
        }
        if name.hasSuffix(".bz2") {
            return try bundledDecoder(data, decoder: sc_bzip2_decompress)
        }
        throw DebExtractorError.unsupportedCompression((name as NSString).pathExtension)
    }
    
    private typealias CDecoder = (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?) -> Int32
    
    /// zstd / bzip2, through the C decoders in Core/Tweaks/Decompress.
    private static func bundledDecoder(_ data: Data, decoder: CDecoder) throws -> Data {
        var output: UnsafeMutablePointer<UInt8>? = nil
        var outputLength = 0
        let status = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            decoder(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &output, &outputLength)
        }
        defer { sc_decompress_free(output) }
        guard status == 0, let decoded = output else { throw DebExtractorError.decompressionFailed }
        return Data(bytes: decoded, count: outputLength)
    }

    private static func gunzip(_ data: Data) throws -> Data {
        // Skip the gzip header to reach the raw deflate stream (RFC 1952).
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
            throw DebExtractorError.decompressionFailed
        }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8 }
        if flags & 0x08 != 0 { while offset < bytes.count && bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x10 != 0 { while offset < bytes.count && bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count else { throw DebExtractorError.decompressionFailed }
        return try stream(Data(bytes[offset...]), algorithm: COMPRESSION_ZLIB)
    }

    private static func stream(_ input: Data, algorithm: compression_algorithm) throws -> Data {
        let bufferSize = 1 << 16
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(dst_ptr: destination, dst_size: bufferSize, src_ptr: destination, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw DebExtractorError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw DebExtractorError.decompressionFailed }
            stream.src_ptr = base
            stream.src_size = input.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(destination, count: bufferSize - stream.dst_size)
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw DebExtractorError.decompressionFailed }
            }
        }
        return output
    }

    // MARK: tar

    private static func tarFiles(_ tar: Data) throws -> [(path: String, data: Data)] {
        var files: [(String, Data)] = []
        var cursor = tar.startIndex
        var longName: String?
        var paxPath: String?

        func field(_ header: Data, _ offset: Int, _ length: Int) -> String {
            let start = header.startIndex + offset
            return String(decoding: header[start..<start + length].prefix { $0 != 0 }, as: UTF8.self)
        }

        while cursor + 512 <= tar.endIndex {
            let header = tar[cursor..<cursor + 512]
            if header.allSatisfy({ $0 == 0 }) { break }

            let name = field(header, 0, 100)
            let sizeText = field(header, 124, 12).trimmingCharacters(in: .whitespaces)
            let size = Int(sizeText, radix: 8) ?? 0
            let type = header[header.startIndex + 156]
            let prefix = field(header, 345, 155)

            let dataStart = cursor + 512
            let dataEnd = min(dataStart + size, tar.endIndex)
            let body = Data(tar[dataStart..<dataEnd])

            switch type {
            case UInt8(ascii: "L"):     // GNU long name for the next entry
                longName = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "x"):     // pax extended header
                let text = String(decoding: body, as: UTF8.self)
                for line in text.split(separator: "\n") where line.contains(" path=") {
                    if let range = line.range(of: " path=") { paxPath = String(line[range.upperBound...]) }
                }
            case UInt8(ascii: "0"), 0:   // regular file
                var path = prefix.isEmpty ? name : prefix + "/" + name
                if let override = paxPath ?? longName { path = override }
                files.append((path, body))
                longName = nil
                paxPath = nil
            default:
                longName = nil
                paxPath = nil
            }

            cursor = dataStart + ((size + 511) / 512) * 512
        }
        return files
    }
}
