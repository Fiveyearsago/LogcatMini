import Foundation

public enum RequestLogImporter {
    /// Associate only the same trace, or a bounded same-thread request block. Never search by URL alone.
    public static func extract(selected original: LogEntry, context: [LogEntry]) -> ReplayRequest {
        let position = context.firstIndex(where: { $0.id == original.id })
        let nearby = position.map { Array(context[max(0, $0 - 600)..<min(context.count, $0 + 601)]) } ?? [original]
        var logical: [LogEntry] = []
        for entry in nearby {
            if var previous = logical.last, isContinuation(entry, of: previous),
               previous.pid == entry.pid, previous.tid == entry.tid, previous.tag == entry.tag,
               previous.date == entry.date, abs(seconds(previous.time) - seconds(entry.time)) <= 2,
               previous.message.utf8.count + entry.message.utf8.count <= 2 * 1_024 * 1_024 {
                logical.removeLast()
                if previous.sourceIDs.isEmpty { previous.sourceIDs = [previous.id] }
                previous.sourceIDs.append(entry.id); previous.message += "\n" + entry.message
                logical.append(previous)
            } else { logical.append(entry) }
        }
        let selected = logical.first { $0.id == original.id || $0.sourceIDs.contains(original.id) } ?? original
        var request = ReplayRequest()
        request.source = "\(selected.date) \(selected.time) · \(selected.tag) · PID \(selected.pid)"
        let sameSource = logical.filter { $0.pid == selected.pid && $0.tag == selected.tag && $0.date == selected.date }
        let trace = capture(#"\btrace_id=([^\s]+)"#, selected.message)
        var entries: [LogEntry]
        if let trace {
            entries = sameSource.filter { capture(#"\btrace_id=([^\s]+)"#, $0.message) == trace }
        } else {
            let thread = sameSource.filter { $0.tid == selected.tid && abs(seconds($0.time) - seconds(selected.time)) <= 10 }
            let index = thread.firstIndex(where: { $0.id == selected.id }) ?? 0
            if let start = thread.indices.prefix(index + 1).last(where: { startLine(thread[$0].message) != nil }) {
                let end = thread.indices.dropFirst(start + 1).first(where: { startLine(thread[$0].message) != nil || thread[$0].message.contains("<--") }) ?? thread.count
                entries = index <= end ? Array(thread[start..<end]) : [selected]
            } else { entries = [selected] }
        }
        // Bound parsing even when a malformed log contains many enormous fragments.
        var byteCount = 0
        entries = entries.filter { byteCount += $0.message.utf8.count; return byteCount <= 4 * 1_024 * 1_024 }
        let text = entries.map(\.displayMessage).joined(separator: "\n")
        let lines = text.components(separatedBy: .newlines)
        if let start = lines.compactMap({ startLine($0) }).first { request.method = start.0; request.url = start.1 }
        else {
            request.url = capture(#"https?://[^\s<>\"']+"#, selected.message, group: 0)?.trimmingCharacters(in: CharacterSet(charactersIn: ",)}]")) ?? ""
            if let method = capture(#"(?i)\bmethod\s*[:=]\s*[\"']?(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)"#, selected.message) { request.method = method.uppercased() }
            else { appendNote("未识别请求方法，暂设 GET，请核对。", to: &request) }
        }
        if let named = entries.compactMap({ namedRequest($0.displayMessage) }).first,
           let body = named.body, !["GET", "HEAD"].contains(named.method) {
            // HttpMobileClient prints the complete JSON after the request envelope's params:.
            // Keep it verbatim, including escaped slashes and Base64 characters in s.
            request.body = body
        } else if let body = payload(label: #"request\s*body|requestBody|post params"#, entries: entries) { request.body = body }
        if let header = payload(label: #"request\s*headers|requestHeaders"#, entries: entries) {
            if let object = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any] {
                request.headers = object.keys.sorted().map { "\($0): \(object[$0]!)" }.joined(separator: "\n")
            } else { request.headers = header }
        }
        // OkHttp BODY logging: start line, headers, blank line, body, --> END.
        let hasLabeledPayload = text.range(of: #"(?i)request\s*(body|headers|params)|post params"#, options: .regularExpression) != nil
        if request.body.isEmpty, !hasLabeledPayload, let start = lines.firstIndex(where: { startLine($0) != nil }) {
            var headerLines: [String] = [], bodyLines: [String] = [], inBody = false
            for line in lines.dropFirst(start + 1) {
                if line.contains("--> END") || line.contains("<--") { break }
                if line.trimmingCharacters(in: .whitespaces).isEmpty { if !headerLines.isEmpty { inBody = true }; continue }
                if line.hasPrefix("{") || line.hasPrefix("[") { inBody = true }
                if inBody { bodyLines.append(line) }
                else if line.range(of: #"^[A-Za-z0-9_-]+:\s"#, options: .regularExpression) != nil { headerLines.append(line) }
            }
            if request.headers.isEmpty { request.headers = headerLines.joined(separator: "\n") }
            request.body = bodyLines.joined(separator: "\n")
        }
        if request.body.contains("run-as ") || request.body.contains("<omitted") || request.body.contains("<not retained") {
            request.body = ""
            appendNote("请求体未打印，或日志仅提供了缓存文件命令；请粘贴完整请求体。", to: &request)
        }
        if request.body == "<empty>" { request.body = "" }
        if request.body.isEmpty && ["POST", "PUT", "PATCH"].contains(request.method) {
            appendNote("未取得完整 Body，请补全后发送。", to: &request)
        }
        if request.body.contains("<redacted>") { appendNote("参数包含脱敏内容，需要补全。", to: &request) }
        if !request.body.isEmpty && !request.headers.lowercased().contains("content-type:") {
            if (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) != nil {
                request.headers += (request.headers.isEmpty ? "" : "\n") + "Content-Type: application/json; charset=utf-8"
            } else if request.body.hasPrefix("s=") {
                request.headers += (request.headers.isEmpty ? "" : "\n") + "Content-Type: application/x-www-form-urlencoded"
            }
        }
        if request.url.isEmpty { appendNote("没有识别到完整请求地址，请填写 URL。", to: &request) }
        request.name = URLComponents(string: request.url).map { request.method + " " + ($0.path.isEmpty ? ($0.host ?? "接口") : $0.path) } ?? "未命名请求"
        return request
    }

    private static func isContinuation(_ entry: LogEntry, of previous: LogEntry) -> Bool {
        if entry.raw == entry.message { return true }
        // logcat -v threadtime repeats metadata on each physical line of one Android message.
        // Only attach unlabeled payload lines with the exact same timestamp; never another log call.
        guard entry.time == previous.time,
              previous.displayMessage.range(of: #"(?i)^request\s*(body|headers|params)\b"#, options: .regularExpression) != nil,
              entry.message == entry.displayMessage,
              entry.message.range(of: #"(?i)^(?:request|response)\s*(body|headers|params)\b|^-->|^<--"#, options: .regularExpression) == nil else { return false }
        return true
    }

    private static func startLine(_ text: String) -> (String, String)? {
        // Match the envelope before scanning for methods/URLs that may also occur inside params.
        if let named = namedRequest(text) { return (named.method, named.url) }
        if let method = capture(#"(?i)(?:-->|\b)(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(https?://[^\s]+)"#, text),
           let url = capture(#"(?i)(?:-->|\b)(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(https?://[^\s]+)"#, text, group: 2) { return (method.uppercased(), url) }
        if let method = capture(#"(?i)\b(get|post)(?: buffer)? url\s*->\s*(https?://[^\s]+)"#, text),
           let url = capture(#"(?i)\b(get|post)(?: buffer)? url\s*->\s*(https?://[^\s]+)"#, text, group: 2) { return (method.uppercased(), url) }
        return nil
    }
    private static func namedRequest(_ text: String) -> (method: String, url: String, body: String?)? {
        let text = LogMessageDisplay.clean(text)
        let pattern = #"(?i)^[\t ]*(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)[\t ]+request[\t ]+[^,\r\n]+,[\t ]*(https?://[^\s]+?)(?=[\t ]*(?:,[\t ]*params[\t ]*:|$))"#
        guard let range = text.range(of: pattern, options: .regularExpression),
              let method = capture(pattern, text), let url = capture(pattern, text, group: 2) else { return nil }
        let tail = String(text[range.upperBound...])
        let label = tail.range(of: #"(?i)^[\t ]*,[\t ]*params[\t ]*:\s*"#, options: .regularExpression)
        let body = label.map { String(tail[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (method.uppercased(), url, body)
    }
    private static func payload(label: String, entries: [LogEntry]) -> String? {
        let pattern = "(?i)(?:" + label + ")(?=\\s|[:=]|$)"
        var pieces: [(Int, Int, String)] = []
        for (index, entry) in entries.enumerated() {
            let text = entry.displayMessage
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let tail = String(text[range.upperBound...])
            let part = capture(#"^\s*\[(\d+)/(\d+)\]"#, tail).flatMap(Int.init)
            let total = capture(#"^\s*\[(\d+)/(\d+)\]"#, tail, group: 2).flatMap(Int.init)
            var value: String
            if let newline = tail.firstIndex(of: "\n") { value = String(tail[tail.index(after: newline)...]) }
            else if let equal = tail.range(of: #"^\s*(?:\[\d+/\d+\])?\s*[:=]\s*"#, options: .regularExpression) { value = String(tail[equal.upperBound...]) }
            else {
                // LogInbox retains a separate entry for the physical continuation line.
                value = entries.dropFirst(index + 1).prefix(while: {
                    $0.tid == entry.tid && $0.raw == $0.message && !$0.message.contains("trace_id=")
                        && !$0.message.contains("<--") && startLine($0.message) == nil
                }).map(\.message).joined(separator: "\n")
            }
            if let part, let total { pieces.append((part, total, value)) }
            else if !value.isEmpty { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let total = pieces.first?.1, pieces.count == total,
              pieces.enumerated().allSatisfy({ $0.element.0 == $0.offset + 1 && $0.element.1 == total }) else { return nil }
        return pieces.map { $0.2 }.joined()
    }
    private static func capture(_ pattern: String, _ text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    private static func seconds(_ text: String) -> Double {
        let fields = text.split(separator: ":").compactMap { Double($0) }
        return fields.count == 3 ? fields[0] * 3600 + fields[1] * 60 + fields[2] : 0
    }
    private static func appendNote(_ note: String, to request: inout ReplayRequest) {
        request.importNotes += (request.importNotes.isEmpty ? "" : "\n") + note
    }
}
