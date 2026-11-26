import Foundation

/// Consecutive numbered chunks and unnumbered OkHttp JSON bodies. Unknown totals require complete JSON.
enum LogChunkMerger {
    private struct Chunk {
        let index: Int
        let total: Int?
        let prefix: String
        let field: String
        let payload: String
        var style = "field"
        var key = ""
        var maximumSeconds: Double = 2
        var requireJSON = false
    }
    private static let marker = try! NSRegularExpression(pattern: #"^(.*?)\b([A-Za-z][A-Za-z0-9_]*)_part=(\d+)/(\d+)\s+\2=(.*)$"#, options: [.dotMatchesLineSeparators])
    // Generic numbered envelope: the payload label may be data/body/content/etc.
    // Keep the whole repeated context (including log_id/status) as the group key.
    private static let envelopeMarker = try! NSRegularExpression(pattern: #"^((?:[A-Za-z][A-Za-z0-9_]*=[^\s]+[\t ]+)*)part=(\d+)/(\d+)[\t ]+([A-Za-z][A-Za-z0-9_]*)=(.*)$"#, options: [.dotMatchesLineSeparators])
    // Remove at most the logger's one separator space, preserving whitespace inside split JSON strings.
    private static let zeroBasedMarker = try! NSRegularExpression(pattern: #"^part_(\d+):[\t ]?(.*)$"#, options: [.dotMatchesLineSeparators])
    private static let countedMarker = try! NSRegularExpression(pattern: #"^\((\d+)/(\d+)\)[\t ]?(.*)$"#, options: [.dotMatchesLineSeparators])
    private static let sequenceMarker = try! NSRegularExpression(pattern: #"^(.*?\bseq=[^\s]+)[\t ]+part=(\d+)/(\d+)[\t ](.*)$"#, options: [.dotMatchesLineSeparators])
    private static func chunk(_ entry: LogEntry, rules: [CompiledLogMergeRule], includesBuiltInRules: Bool) -> Chunk? {
        guard entry.mergedParts == 1 else { return nil }
        for compiled in rules {
            if let match = compiled.match(entry) {
                return Chunk(index: match.index, total: match.total, prefix: match.prefix, field: "", payload: match.body,
                             style: compiled.rule.id.uuidString, key: match.key, maximumSeconds: compiled.rule.maximumSeconds,
                             requireJSON: compiled.rule.requireJSON)
            }
        }
        guard includesBuiltInRules else { return nil }
        guard entry.mergedParts == 1,
              entry.message.contains("part=") || entry.message.contains("part_") || entry.message.contains("(") else { return nil }
        let message = entry.displayMessage
        if let match = envelopeMarker.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
            func field(_ n: Int) -> String { String(message[Range(match.range(at: n), in: message)!]) }
            guard let index = Int(field(2)), let total = Int(field(3)), total >= 2, total <= 256, index >= 1, index <= total else { return nil }
            return Chunk(index: index, total: total, prefix: field(1), field: field(4), payload: field(5), style: "envelope")
        }
        let text = entry.displayMessage
        if let match = sequenceMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            func value(_ n: Int) -> String { String(text[Range(match.range(at: n), in: text)!]) }
            guard let index = Int(value(2)), let total = Int(value(3)), (2...256).contains(total), (1...total).contains(index) else { return nil }
            return Chunk(index: index, total: total, prefix: value(1) + " ", field: "", payload: value(4), style: "sequence", key: value(1))
        }
        if let match = countedMarker.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
            func field(_ n: Int) -> String { String(message[Range(match.range(at: n), in: message)!]) }
            guard let index = Int(field(1)), let total = Int(field(2)), total >= 2, total <= 256, index >= 1, index <= total else { return nil }
            // The response header belongs to the first payload; later parts continue it verbatim.
            return Chunk(index: index, total: total, prefix: "", field: "", payload: field(3), style: "counted")
        }
        if let match = zeroBasedMarker.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let indexRange = Range(match.range(at: 1), in: message), let index = Int(message[indexRange]), index < 256,
           let payloadRange = Range(match.range(at: 2), in: message) {
            return Chunk(index: index + 1, total: nil, prefix: "", field: "", payload: String(message[payloadRange]), style: "zero")
        }
        guard let match = marker.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return nil }
        func field(_ n: Int) -> String { String(message[Range(match.range(at: n), in: message)!]) }
        guard let index = Int(field(3)), let total = Int(field(4)), total >= 2, total <= 256, index >= 1, index <= total else { return nil }
        return Chunk(index: index, total: total, prefix: field(1), field: field(2), payload: field(5))
    }
    private static func seconds(_ time: String) -> Double? {
        // Unified iOS timestamps include a numeric timezone suffix (e.g. +0800).
        let clock = time.prefix { $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") }
        let fields = clock.split(separator: ":")
        guard fields.count == 3, let h = Double(fields[0]), let m = Double(fields[1]), let s = Double(fields[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
    static func mergeTail(_ entries: inout [LogEntry], rules: [CompiledLogMergeRule] = [], includesBuiltInRules: Bool = true) {
        guard let last = entries.last else { return }
        guard let end = chunk(last, rules: rules, includesBuiltInRules: includesBuiltInRules) else { if includesBuiltInRules { mergeOkHTTPJSONTail(&entries) }; return }
        let count = end.total ?? end.index
        guard count >= 2, end.index == count, entries.count >= count else { return }
        let parts = Array(entries.suffix(count))
        guard let first = parts.first, let startTime = seconds(first.time), let endTime = seconds(last.time),
              endTime >= startTime, endTime - startTime <= end.maximumSeconds else { return }
        var payload = "", previousTime = startTime, bytes = 0
        for (offset, entry) in parts.enumerated() {
            guard entry.date == first.date, entry.pid == first.pid, entry.tid == first.tid,
                  entry.tag == first.tag, entry.level == first.level,
                  entry.id == first.id + UInt64(offset),
                  let time = seconds(entry.time), time >= previousTime,
                  let part = chunk(entry, rules: rules, includesBuiltInRules: includesBuiltInRules), part.index == offset + 1, part.total == end.total,
                  part.prefix == end.prefix, part.field == end.field, part.style == end.style, part.key == end.key else { return }
            previousTime = time; bytes += entry.raw.utf8.count
            guard bytes <= 2 * 1_024 * 1_024 else { return }
            payload += part.payload
        }
        // part_0/part_1/... has no final marker. Incomplete or non-JSON content stays as original rows.
        if end.total == nil || end.requireJSON {
            guard (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil else { return }
        }
        var merged = first
        merged.message = end.prefix + (end.field.isEmpty ? "" : end.field + "=") + payload
        merged.raw = parts.map(\.raw).joined(separator: "\n")
        merged.sourceIDs = parts.map(\.id)
        merged.originalParts = Array(parts)
        entries.removeLast(count); entries.append(merged)
    }

    private static func mergeOkHTTPJSONTail(_ entries: inout [LogEntry]) {
        guard let last = entries.last, last.tag == "okhttp.OkHttpClient", last.mergedParts == 1,
              entries.count >= 2, let endTime = seconds(last.time),
              let ending = last.message.utf8.last(where: { !JSONContainerBoundary.isSpace($0) }),
              ending == 0x7d || ending == 0x5d else { return }
        // With no part numbers, do not cross an HTTP envelope, another source, an ID gap or a time gap.
        var start = entries.count - 1, bytes = last.raw.utf8.count
        guard bytes <= 2 * 1_024 * 1_024 else { return }
        while start > 0 {
            let previous = entries[start - 1], next = entries[start]
            guard previous.mergedParts == 1, previous.date == last.date, previous.pid == last.pid,
                  previous.tid == last.tid, previous.tag == last.tag, previous.level == last.level,
                  previous.id < UInt64.max, previous.id + 1 == next.id,
                  let time = seconds(previous.time), let nextTime = seconds(next.time),
                  time <= nextTime, endTime - time <= 2 else { break }
            let message = previous.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasPrefix("<--") || message.hasPrefix("-->") { break }
            // Refuse an overlong run instead of treating an inner object as a new root after truncation.
            guard entries.count - start < 256 else { return }
            bytes += previous.raw.utf8.count
            guard bytes <= 2 * 1_024 * 1_024 else { return }
            start -= 1
        }

        var candidate: Int?, payload = "", scanner = JSONContainerBoundary()
        for index in start..<entries.count {
            let message = entries[index].message
            if candidate == nil {
                guard let first = message.utf8.first(where: { !JSONContainerBoundary.isSpace($0) }),
                      first == 0x7b || first == 0x5b else { continue }
                candidate = index; payload = ""; scanner = JSONContainerBoundary()
            }
            payload += message
            scanner.append(message)
            if scanner.invalid {
                candidate = nil; payload = ""
            } else if scanner.complete {
                if let candidate, candidate < index, index == entries.count - 1,
                   (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil {
                    let parts = entries[candidate...]
                    var merged = entries[candidate]
                    merged.message = payload
                    merged.raw = parts.map(\.raw).joined(separator: "\n")
                    merged.sourceIDs = parts.map(\.id)
                    merged.originalParts = Array(parts)
                    entries.removeLast(entries.count - candidate); entries.append(merged)
                    return
                }
                // A complete record is a boundary, including malformed JSON with balanced brackets.
                candidate = nil; payload = ""
            }
        }
    }

    /// Tracks the outer container across rows, so a complete nested object cannot merge on its own.
    private struct JSONContainerBoundary {
        private var closing: [UInt8] = []
        private var inString = false
        private var escaped = false
        private var started = false
        private(set) var invalid = false
        var complete: Bool { started && closing.isEmpty && !inString && !invalid }
        static func isSpace(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0a, 0x0d].contains(byte) }
        mutating func append(_ text: String) {
            for byte in text.utf8 {
                if inString {
                    if byte < 0x20 { invalid = true; return }
                    if escaped { escaped = false }
                    else if byte == 0x5c { escaped = true }
                    else if byte == 0x22 { inString = false }
                    continue
                }
                if Self.isSpace(byte) { continue }
                if complete { invalid = true; return }
                switch byte {
                case 0x7b: closing.append(0x7d); started = true
                case 0x5b: closing.append(0x5d); started = true
                case 0x7d, 0x5d:
                    guard closing.popLast() == byte else { invalid = true; return }
                case 0x22: inString = true
                default: break // Full JSON syntax is validated only when the outer container closes.
                }
            }
        }
    }
}
