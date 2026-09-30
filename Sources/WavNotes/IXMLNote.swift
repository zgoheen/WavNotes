import Foundation

enum IXMLError: LocalizedError {
    case notWave
    case malformed(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notWave: return "Not a RIFF/RF64 WAVE file."
        case .malformed(let msg): return "Malformed file: \(msg)"
        case .tooLarge: return "File would exceed the 4 GB RIFF limit."
        }
    }
}

/// Reads and writes the iXML <NOTE> field of a WAV/BWF file, in place.
///
/// Only the iXML chunk (and the RIFF size field) are ever touched; audio data is never rewritten.
/// - iXML is the last chunk: the file is truncated there and the new chunk appended.
/// - iXML sits mid-file and the new XML fits: overwritten in place, padded with whitespace.
/// - iXML sits mid-file and the new XML doesn't fit: the old chunk is renamed to JUNK
///   (which every RIFF reader skips) and a new iXML chunk is appended.
/// - No iXML chunk: one is appended.
enum IXMLNote {
    private struct Chunk {
        let id: String
        let headerOffset: UInt64
        let size: UInt64
        var dataOffset: UInt64 { headerOffset + 8 }
        var end: UInt64 { dataOffset + size + (size & 1) }
    }

    private struct Layout {
        let isRF64: Bool
        let chunks: [Chunk]
        let fileLength: UInt64
    }

    // MARK: Public

    static func readNote(from url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let layout = try parse(handle)
        guard let chunk = layout.chunks.first(where: { $0.id == "iXML" }) else { return nil }
        guard let xml = try readXML(handle, chunk) else { return nil }
        return extractNote(from: xml)
    }

    static func writeNote(_ note: String, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let layout = try parse(handle)
        let existing = layout.chunks.last(where: { $0.id == "iXML" })
        let oldXML = try existing.flatMap { try readXML(handle, $0) }
        var xmlData = Data(updatedXML(oldXML, note: note).utf8)

        if let existing, existing.end >= layout.fileLength {
            // Last chunk: rewrite the tail.
            try handle.truncate(atOffset: existing.headerOffset)
            try append(xmlData, to: handle)
        } else if let existing, UInt64(xmlData.count) <= existing.size {
            // Fits in the existing chunk: overwrite, pad with whitespace (legal after the root element).
            xmlData.append(Data(repeating: 0x20, count: Int(existing.size) - xmlData.count))
            try handle.seek(toOffset: existing.dataOffset)
            try handle.write(contentsOf: xmlData)
        } else {
            if let existing {
                try handle.seek(toOffset: existing.headerOffset)
                try handle.write(contentsOf: Data("JUNK".utf8))
            }
            try handle.seek(toOffset: layout.fileLength)
            if layout.fileLength & 1 == 1 {
                try handle.write(contentsOf: Data([0]))
            }
            try append(xmlData, to: handle)
        }

        try updateRiffSize(handle, isRF64: layout.isRF64)
        try handle.synchronize()
    }

    // MARK: XML

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let noteRegex = try! NSRegularExpression(pattern: "<NOTE\\s*/>|<NOTE>[\\s\\S]*?</NOTE>")

    static func updatedXML(_ xml: String?, note: String) -> String {
        let element = "<NOTE>\(escape(note))</NOTE>"
        if let xml, xml.contains("</BWFXML>") {
            let range = NSRange(xml.startIndex..., in: xml)
            if let match = noteRegex.firstMatch(in: xml, range: range), let r = Range(match.range, in: xml) {
                return xml.replacingCharacters(in: r, with: element)
            }
            return xml.replacingOccurrences(of: "</BWFXML>", with: "\t\(element)\n</BWFXML>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <BWFXML>
        \t<IXML_VERSION>2.10</IXML_VERSION>
        \t\(element)
        </BWFXML>

        """
    }

    static func extractNote(from xml: String) -> String? {
        guard let doc = try? XMLDocument(xmlString: xml),
              let node = try? doc.nodes(forXPath: "/BWFXML/NOTE").first
        else { return nil }
        return node.stringValue
    }

    // MARK: RIFF

    private static func parse(_ handle: FileHandle) throws -> Layout {
        let fileLength = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.fourCC(at: 8) == "WAVE"
        else { throw IXMLError.notWave }

        let riffID = header.fourCC(at: 0)
        let isRF64 = riffID == "RF64" || riffID == "BW64"
        guard isRF64 || riffID == "RIFF" else { throw IXMLError.notWave }

        var chunks: [Chunk] = []
        var rf64DataSize: UInt64?
        var offset: UInt64 = 12
        while offset + 8 <= fileLength {
            try handle.seek(toOffset: offset)
            guard let h = try handle.read(upToCount: 8), h.count == 8 else { break }
            let id = h.fourCC(at: 0)
            var size = UInt64(h.uint32LE(at: 4))

            if id == "ds64" {
                let ds = try handle.read(upToCount: 16) ?? Data()
                if ds.count == 16 { rf64DataSize = ds.uint64LE(at: 8) }
            }
            if isRF64, id == "data", size == 0xFFFF_FFFF, let real = rf64DataSize {
                size = real
            }
            // Some recorders leave a truncated final chunk; clamp so we don't run past EOF.
            size = min(size, fileLength - offset - 8)
            let chunk = Chunk(id: id, headerOffset: offset, size: size)
            chunks.append(chunk)
            offset = chunk.end
        }
        guard chunks.contains(where: { $0.id == "fmt " }) else { throw IXMLError.malformed("no fmt chunk") }
        return Layout(isRF64: isRF64, chunks: chunks, fileLength: fileLength)
    }

    private static func readXML(_ handle: FileHandle, _ chunk: Chunk) throws -> String? {
        try handle.seek(toOffset: chunk.dataOffset)
        guard let data = try handle.read(upToCount: Int(chunk.size)) else { return nil }
        let trimmed = data.prefix { $0 != 0 }
        return String(data: trimmed, encoding: .utf8) ?? String(data: trimmed, encoding: .isoLatin1)
    }

    /// Writes an iXML chunk at the handle's current position.
    private static func append(_ xml: Data, to handle: FileHandle) throws {
        var chunk = Data("iXML".utf8)
        chunk.appendUInt32LE(UInt32(xml.count))
        chunk.append(xml)
        if xml.count & 1 == 1 { chunk.append(0) }
        try handle.write(contentsOf: chunk)
    }

    private static func updateRiffSize(_ handle: FileHandle, isRF64: Bool) throws {
        let length = try handle.seekToEnd()
        let riffSize = length - 8
        if isRF64 {
            // riffSize lives in the first 8 bytes of ds64, which must be the first chunk.
            try handle.seek(toOffset: 12)
            guard let h = try handle.read(upToCount: 4), h.fourCC(at: 0) == "ds64" else {
                throw IXMLError.malformed("RF64 without leading ds64 chunk")
            }
            var d = Data()
            d.appendUInt64LE(riffSize)
            try handle.seek(toOffset: 20)
            try handle.write(contentsOf: d)
        } else {
            guard riffSize <= UInt64(UInt32.max) else { throw IXMLError.tooLarge }
            var d = Data()
            d.appendUInt32LE(UInt32(riffSize))
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: d)
        }
    }
}

private extension Data {
    func fourCC(at i: Int) -> String {
        String(decoding: self[startIndex + i ..< startIndex + i + 4], as: UTF8.self)
    }

    func uint32LE(at i: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + i + $1]) << (8 * $1) }
    }

    func uint64LE(at i: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(self[startIndex + i + $1]) << (8 * $1) }
    }

    mutating func appendUInt32LE(_ v: UInt32) {
        for i in 0..<4 { append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
    }

    mutating func appendUInt64LE(_ v: UInt64) {
        for i in 0..<8 { append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
    }
}
