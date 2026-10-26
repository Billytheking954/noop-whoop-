import Foundation

/// Checks a privately staged legacy SQLite WAL before SQLite can silently ignore damaged frames.
/// Format and checksum rules: https://www.sqlite.org/fileformat2.html#walformat
/// Memory use is bounded by one page. Old frames after a WAL reset are not current-epoch data.
public enum SQLiteWALIntegrity {
    public static func failure(atPath path: String, databaseAtPath databasePath: String) -> String? {
        do {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            let header = try read(file, count: 32)
            // A TRUNCATE checkpoint legitimately leaves an empty WAL beside a complete main file.
            if header.isEmpty { return nil }
            guard header.count == 32 else { return "The backup WAL header is truncated." }
            let magic = word(header, at: 0)
            guard magic == 0x377f0682 || magic == 0x377f0683,
                  word(header, at: 4) == 3_007_000 else {
                return "The backup WAL header has an unsupported format."
            }
            let pageSize = Int(word(header, at: 8))
            guard pageSize >= 512, pageSize <= 65_536, pageSize & (pageSize - 1) == 0 else {
                return "The backup WAL page size is invalid."
            }
            let littleEndian = magic == 0x377f0682
            var sums = checksum(header, count: 24, seed: (0, 0), littleEndian: littleEndian)
            guard sums.0 == word(header, at: 24), sums.1 == word(header, at: 28) else {
                return "The backup WAL header checksum is invalid."
            }
            let main = try FileHandle(forReadingFrom: URL(fileURLWithPath: databasePath))
            defer { try? main.close() }
            let mainHeader = try read(main, count: 18)
            guard mainHeader.count == 18,
                  Array(mainHeader.prefix(16)) == Array("SQLite format 3".utf8) + [0] else {
                return "The backup main database header is invalid."
            }
            let encodedPageSize = Int(mainHeader[16]) << 8 | Int(mainHeader[17])
            guard pageSize == (encodedPageSize == 1 ? 65_536 : encodedPageSize) else {
                return "The backup WAL and main database page sizes differ."
            }

            var sawResetTail = false
            while true {
                let frame = try read(file, count: 24)
                if frame.isEmpty { return nil }
                guard frame.count == 24 else { return "The backup WAL frame header is truncated." }
                let page = try read(file, count: pageSize)
                guard page.count == pageSize else { return "The backup WAL page is truncated." }

                let frameMatchesEpoch = word(frame, at: 8) == word(header, at: 16)
                    && word(frame, at: 12) == word(header, at: 20)
                if sawResetTail {
                    // A valid reset leaves only old-epoch frames after the first old-epoch frame.
                    // Seeing a current-epoch frame later means an earlier frame's salt was damaged.
                    guard !frameMatchesEpoch else {
                        return "The backup WAL contains a current-epoch frame after its reset tail."
                    }
                    continue
                }
                if !frameMatchesEpoch {
                    // The salts are not covered by the frame checksum. If this frame's checksum still
                    // matches the active rolling checksum, it is a current-epoch frame with a damaged
                    // salt, not a stale checkpoint-reset tail. Check this before accepting the tail.
                    var candidate = checksum(frame, count: 8, seed: sums, littleEndian: littleEndian)
                    candidate = checksum(page, count: pageSize, seed: candidate, littleEndian: littleEndian)
                    guard candidate.0 != word(frame, at: 16) || candidate.1 != word(frame, at: 20) else {
                        return "The backup WAL frame salt is invalid for the current checksum chain."
                    }
                    sawResetTail = true
                    continue
                }

                let pageNumber = word(frame, at: 0)
                guard pageNumber > 0, pageNumber < UInt32.max,
                      word(frame, at: 4) < UInt32.max else {
                    return "The backup WAL frame page number is invalid."
                }
                sums = checksum(frame, count: 8, seed: sums, littleEndian: littleEndian)
                sums = checksum(page, count: pageSize, seed: sums, littleEndian: littleEndian)
                guard sums.0 == word(frame, at: 16), sums.1 == word(frame, at: 20) else {
                    return "The backup WAL frame checksum is invalid."
                }
            }
        } catch {
            return "Couldn't read the backup WAL: \(error.localizedDescription)"
        }
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            guard let part = try file.read(upToCount: count - bytes.count), !part.isEmpty else { break }
            bytes.append(part)
        }
        return bytes
    }

    private static func word(_ bytes: Data, at offset: Int, littleEndian: Bool = false) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            let shift = littleEndian ? index * 8 : (3 - index) * 8
            value |= UInt32(bytes[offset + index]) << shift
        }
        return value
    }

    private static func checksum(_ bytes: Data, count: Int, seed: (UInt32, UInt32),
                                 littleEndian: Bool) -> (UInt32, UInt32) {
        var (first, second) = seed
        for offset in stride(from: 0, to: count, by: 8) {
            first = first &+ word(bytes, at: offset, littleEndian: littleEndian) &+ second
            second = second &+ word(bytes, at: offset + 4, littleEndian: littleEndian) &+ first
        }
        return (first, second)
    }
}
