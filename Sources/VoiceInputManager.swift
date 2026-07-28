import AVFoundation
import Compression
import Network
import AppKit
import CoreGraphics
import Foundation
import CryptoKit
import zlib

class VoiceInputManager {
    static let shared = VoiceInputManager()

    private var audioEngine: AVAudioEngine?
    private var wasRecording = false
    private var streamTask: Task<Void, Never>?
    private var sendTask: Task<Void, Error>?
    private var recvTask: Task<Void, Error>?
    private var wsConnection: NWConnection?
    private var micBuf = Data()
    private var micSeq: Int32 = 2
    private var lastToggleTime: Date = .distantPast
    private var latestText = ""
    private var typedText = ""
    private let defaults = UserDefaults.standard

    var volcengineAppKey: String {
        get { defaults.string(forKey: "VolcengineAppKey") ?? "" }
        set { defaults.set(newValue, forKey: "VolcengineAppKey") }
    }
    var volcengineAccessKey: String {
        get { defaults.string(forKey: "VolcengineAccessKey") ?? "" }
        set { defaults.set(newValue, forKey: "VolcengineAccessKey") }
    }
    var volcengineSecretKey: String {
        get { defaults.string(forKey: "VolcengineSecretKey") ?? "" }
        set { defaults.set(newValue, forKey: "VolcengineSecretKey") }
    }
    var isReady: Bool { !volcengineAppKey.isEmpty && !volcengineAccessKey.isEmpty }

    func toggleVoiceInput() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) >= 0.5 else { return }
        lastToggleTime = now

        if wasRecording {
            stopEverything()
        } else {
            startStreaming()
        }
    }

    private func stopEverything() {
        guard wasRecording else { return }
        wasRecording = false
        postStateNotification(false)
        log("停止录音…")

        // Inject any remaining untyped suffix via backspace+type logic
        let finalText = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cp = commonPrefixLen(typedText, finalText)
        let deleteCount = typedText.count - cp
        let suffixIdx = finalText.index(finalText.startIndex, offsetBy: cp)
        let remaining = String(finalText[suffixIdx...])
        latestText = ""
        typedText = ""

        wsConnection?.cancel()
        wsConnection = nil
        recvTask?.cancel()
        sendTask?.cancel()
        streamTask?.cancel()
        recvTask = nil
        sendTask = nil
        streamTask = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        micBuf.removeAll()
        micSeq = 2

        if !remaining.isEmpty {
            // Use same backspace+append logic: first delete any stale suffix, then type new
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let source = CGEventSource(stateID: .hidSystemState)
                if deleteCount > 0 {
                    let backspace: CGKeyCode = 0x33
                    for _ in 0..<deleteCount {
                        if let down = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: true) { down.post(tap: .cghidEventTap) }
                        if let up = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: false) { up.post(tap: .cghidEventTap) }
                        usleep(1000)
                    }
                }
                for char in remaining.utf16 {
                    var codeUnit = char
                    if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit); down.post(tap: .cghidEventTap)
                    }
                    if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit); up.post(tap: .cghidEventTap)
                    }
                    usleep(1000)
                }
            }
        }

        log("已停止")
    }

    private func startStreaming() {
        guard !wasRecording, isReady else { showError("请先填写 API 凭证"); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { g in if g { DispatchQueue.main.async { self.startStreaming() } } }
            return
        case .denied, .restricted: showError("请允许麦克风权限"); return
        default: break
        }
        latestText = ""
        typedText = ""
        log("开始录音…")
        wasRecording = true; postStateNotification(true)

        let engine = AVAudioEngine()
        audioEngine = engine

        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do { try await self.runStream(engine: engine) }
            catch {
                await MainActor.run {
                    if !self.wasRecording { return }
                    self.log("错误: \(error.localizedDescription)", level: .err)
                    self.stopEverything()
                }
            }
        }
    }

    private func runStream(engine: AVAudioEngine) async throws {
        var hdrs = [
            "X-Api-App-Key": volcengineAppKey,
            "X-Api-Access-Key": volcengineAccessKey,
            "X-Api-Resource-Id": "volc.seedasr.sauc.duration",
            "X-Api-Request-Id": UUID().uuidString,
            "X-Api-Connect-Id": UUID().uuidString,
        ]
        let sec = volcengineSecretKey
        if !sec.isEmpty {
            let ts = String(Int(Date().timeIntervalSince1970))
            hdrs["X-Api-Timestamp"] = ts
            hdrs["X-Api-Signature"] = hmac(appId: volcengineAppKey, token: volcengineAccessKey, ts: ts, secret: sec)
        }
        let ws = try await ManualWS(host: "openspeech.bytedance.com", port: 443,
                                     path: "/api/v3/sauc/bigmodel_async", headers: hdrs, timeout: 60)
        await MainActor.run { self.wsConnection = ws.underlyingConnection }
        defer { try? ws.close() }
        await log("WS 已连接", level: .ok)

        let cfg: [String: Any] = [
            "user": ["uid": "magickey"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                        "enable_ddc": false, "show_utterances": true, "result_type": "full"]
        ]
        let cfgJSON = try JSONSerialization.data(withJSONObject: cfg)
        guard let gz = gzipData(cfgJSON) else { throw NSError(domain: "V", code: 1, userInfo: [NSLocalizedDescriptionKey: "gzip config failed"]) }
        try await ws.send(cfgFrame(gz))
        let ack = try await ws.recv()
        await log("配置 ACK (\(ack.count)B)", level: .ok)

        let sTask = Task<Void, Error> { [weak self] in
            guard let self = self else { return }
            let ok: Bool = await MainActor.run {
                engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
                    guard let self = self, let f = buf.floatChannelData else { return }
                    let n = Int(buf.frameLength)
                    var s = [Int16](repeating: 0, count: n)
                    for i in 0..<n { s[i] = Int16(max(-1, min(1, f.pointee[i])) * 32767) }
                    let raw = Data(bytes: &s, count: n * 2)
                    Task { await self.sendMicChunk(raw, ws: ws) }
                }
                do { try engine.start() } catch { return false }
                return true
            }
            guard ok else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Flush + final frame
            if !self.micBuf.isEmpty {
                let chunk = self.micBuf; self.micBuf.removeAll()
                let pcm16k = self.resample(int16: chunk, from: 44100, to: 16000)
                if let gzFinal = self.gzipData(pcm16k) {
                    var h = Data([0x11, 0x23, 0x01, 0x00])
                    var s = self.micSeq.bigEndian; h.append(Data(bytes: &s, count: 4))
                    var sz = UInt32(gzFinal.count).bigEndian; h.append(Data(bytes: &sz, count: 4))
                    h.append(gzFinal)
                    try? await ws.send(h)
                }
            } else {
                var h = Data([0x11, 0x22, 0x00, 0x00])
                let n = Int32(bitPattern: UInt32(bitPattern: -self.micSeq))
                var s = n.bigEndian; h.append(Data(bytes: &s, count: 4))
                var sz = UInt32(0).bigEndian; h.append(Data(bytes: &sz, count: 4))
                try? await ws.send(h)
            }
            await MainActor.run {
                engine.stop(); engine.inputNode.removeTap(onBus: 0)
            }
        }
        await MainActor.run { self.sendTask = sTask }

        let rTask = Task<Void, Error> { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                let raw = try await ws.recv()
                guard raw.count >= 4 else { continue }
                let mt = raw[1] >> 4
                let fl = raw[1] & 0x0F
                let co = (raw[2] & 0x0F) == 1
                var off = 4
                if (fl & 1) != 0 { off += 4 }

                if mt == 0x0F {
                    guard raw.count >= off + 8 else { break }
                    let errCode = raw.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
                    let msgSize = raw.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
                    let errMsg = raw.count >= off + Int(msgSize) ? String(data: raw.subdata(in: off..<off+Int(msgSize)), encoding: .utf8) ?? "?" : "?"
                    await self.log("API错误 [\(errCode)]: \(errMsg)", level: .err)
                    break
                }

                if mt == 0x09 {
                    guard raw.count >= off + 4 else { continue }
                    let sz = raw.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
                    guard raw.count >= off + Int(sz) else { continue }
                    var b = raw.subdata(in: off..<off+Int(sz))
                    if co, let d = Self.gunzipData(b) { b = d }

                    if let json = try? JSONSerialization.jsonObject(with: b) as? [String: Any],
                       let r = json["result"] as? [String: Any],
                       let text = r["text"] as? String {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        await self.log("实时: \"\(t)\"", level: .data)
                        await MainActor.run { self.handlePartialResult(t) }
                    }

                    if (fl & 2) != 0 {
                        await self.log("服务端完成", level: .ok)
                        break
                    }
                }
            }
        }
        await MainActor.run { self.recvTask = rTask }

        do { _ = try await sTask.value } catch {}
        rTask.cancel()
        _ = await rTask.result

        await MainActor.run { self.stopEverything() }
    }

    private func sendMicChunk(_ raw: Data, ws: ManualWS) async {
        micBuf.append(raw)
        while micBuf.count >= 3200 {
            let chunk = micBuf.prefix(3200)
            micBuf.removeFirst(min(3200, micBuf.count))
            let pcm16k = resample(int16: chunk, from: 44100, to: 16000)
            guard let gz = gzipData(pcm16k) else { return }
            var h = Data([0x11, 0x21, 0x01, 0x00])
            var s = micSeq.bigEndian; h.append(Data(bytes: &s, count: 4))
            var sz = UInt32(gz.count).bigEndian; h.append(Data(bytes: &sz, count: 4))
            h.append(gz); micSeq += 1
            do { try await ws.send(h) } catch { return }
        }
    }

    private func cfgFrame(_ payload: Data) -> Data {
        var h = Data([0x11, 0x10, 0x11, 0x00])
        var sz = UInt32(payload.count).bigEndian; h.append(Data(bytes: &sz, count: 4))
        h.append(payload); return h
    }

    // MARK: - Gzip
    private func gzipData(_ data: Data) -> Data? {
        guard let raw = rawDeflate(data) else { return nil }
        let hdr: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff]
        let crc = UInt32(crc32(0, data.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress }, uInt(data.count)))
        var trailer = Data(); var crcLE = crc.littleEndian; trailer.append(Data(bytes: &crcLE, count: 4))
        var isize = UInt32(data.count).littleEndian; trailer.append(Data(bytes: &isize, count: 4))
        return Data(hdr) + raw + trailer
    }
    private func rawDeflate(_ data: Data) -> Data? {
        let cap = 64 + data.count + data.count / 4; var dst = Data(count: cap)
        let wr = dst.withUnsafeMutableBytes { d in data.withUnsafeBytes { s in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
                s.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) } }
        return wr > 0 ? dst.prefix(wr) : nil
    }
    private static func gunzipData(_ data: Data) -> Data? {
        let step = 256 * 1024; var total = Data()
        data.withUnsafeBytes { raw in var p = raw.bindMemory(to: UInt8.self).baseAddress!; var avail = data.count
            while avail > 0 { var buf = [UInt8](repeating: 0, count: step)
                let wr = compression_decode_buffer(&buf, step, p, avail, nil, COMPRESSION_ZLIB)
                guard wr > 0 else { return }; total.append(contentsOf: buf.prefix(wr)); p += wr; avail -= wr } }
        return total.isEmpty ? nil : total
    }
    private func resample(int16 data: Data, from sr: Double, to target: Double) -> Data {
        guard abs(sr - target) > 1 else { return data }
        let inCount = data.count / 2; let outCount = Int(Double(inCount) * target / sr)
        var out = Data(count: outCount * 2); let ratio = sr / target
        data.withUnsafeBytes { r in let src = r.bindMemory(to: Int16.self)
            out.withUnsafeMutableBytes { r in let dst = r.bindMemory(to: Int16.self)
                for i in 0..<outCount { dst[i] = src[min(Int(Double(i) * ratio), inCount - 1)] } } }
        return out
    }

    // MARK: - Streaming injection with backspace correction
    // When the LLM corrects earlier text, we compute the longest common prefix,
    // send backspaces to erase the changed suffix, then type the corrected suffix.
    // Short delay buffer smooths out rapid corrections before injecting.

    private func handlePartialResult(_ newFullText: String) {
        latestText = newFullText
        let trimmed = newFullText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Compute common prefix
        let cp = commonPrefixLen(typedText, trimmed)
        let deleteCount = typedText.count - cp
        let suffixIdx = trimmed.index(trimmed.startIndex, offsetBy: cp)
        let textToAppend = String(trimmed[suffixIdx...])

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let source = CGEventSource(stateID: .hidSystemState)

            // 1) Delete changed suffix
            if deleteCount > 0 {
                let backspace: CGKeyCode = 0x33
                for _ in 0..<deleteCount {
                    if let down = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: true) {
                        down.post(tap: .cghidEventTap)
                    }
                    if let up = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: false) {
                        up.post(tap: .cghidEventTap)
                    }
                    usleep(1000)
                }
            }

            // 2) Type new suffix
            for char in textToAppend.utf16 {
                var codeUnit = char
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
                    up.post(tap: .cghidEventTap)
                }
                usleep(1000)
            }

            self.typedText = trimmed
        }
    }

    private func commonPrefixLen(_ a: String, _ b: String) -> Int {
        let (s1, s2) = (Array(a), Array(b))
        var i = 0
        while i < s1.count && i < s2.count && s1[i] == s2[i] { i += 1 }
        return i
    }

    // Legacy
    private func injectChars(_ text: String) { typeStringGlobally(text) }
    private func injectViaAccessibility(_ text: String) { typeStringGlobally(text) }
    private func fallbackInjectViaPasteboard(_ text: String) { pasteTextGlobally(text) }

    // MARK: Batch typing helpers

    private func typeStringGlobally(_ text: String) {
        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .hidSystemState)
            for char in text.utf16 {
                var codeUnit = char
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
                    up.post(tap: .cghidEventTap)
                }
                usleep(800)
            }
        }
    }

    // MARK: Silent clipboard paste (for long text)

    private func pasteTextGlobally(_ text: String) {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount

        var previousItems: [(NSPasteboard.PasteboardType, Data)] = []
        if let items = pb.pasteboardItems {
            for item in items {
                if let type = item.types.first, let data = item.data(forType: type) {
                    previousItems.append((type, data))
                }
            }
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .hidSystemState)
            let vKey: CGKeyCode = 0x09
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)!
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)!
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if pb.changeCount == changeCount + 1 {
                    pb.clearContents()
                    for (type, data) in previousItems {
                        pb.setData(data, forType: type)
                    }
                }
            }
        }
    }

    // MARK: - Streaming injection helpers (used from stopEverything)

    // MARK: - Helpers
    private func hmac(appId: String, token: String, ts: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        guard let msg = (appId + token + ts).data(using: .utf8) else { return "" }
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: key)).map { String(format: "%02x", $0) }.joined()
    }
    private func showError(_ msg: String) { LogManager.shared.append(msg, level: .err); let a = NSAlert(); a.messageText = msg; a.runModal() }
    private func log(_ msg: String, level: LogManager.Level = .info) { DispatchQueue.main.async { LogManager.shared.append(msg, level: level) } }
    private func postStateNotification(_ r: Bool) { NotificationCenter.default.post(name: NSNotification.Name("voiceRecordingStateChanged"), object: r) }
    func pressEnter() {}
}

// MARK: - ManualWS
private class ManualWS {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "ws")
    private var buf = Data()

    var underlyingConnection: NWConnection { conn }

    init(host: String, port: UInt16, path: String, headers: [String: String], timeout: TimeInterval) async throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }; req += "\r\n"
        conn = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), using: .tls)
        conn.start(queue: queue)
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak conn] st in
                guard st == .ready, let c = conn else { return }
                c.send(content: Data(req.utf8), completion: .contentProcessed { err in
                    if let err = err { cc.resume(throwing: err); return }
                    c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { d, _, _, err in
                        if let err = err { cc.resume(throwing: err); return }
                        let resp = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        if resp.contains("101") { cc.resume() }
                        else { cc.resume(throwing: NSError(domain: "WS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Handshake failed: \(resp.prefix(200))"])) }
                    }
                })
            }
        }
    }
    func send(_ data: Data) async throws {
        var frame = Data([0x82]); let len = data.count
        if len < 126 { frame.append(UInt8(0x80 | UInt8(len))) }
        else if len < 65536 { frame.append(contentsOf: [UInt8(0x80 | 126)]); var l = UInt16(len).bigEndian; frame.append(Data(bytes: &l, count: 2)) }
        else { frame.append(contentsOf: [UInt8(0x80 | 127)]); var l = UInt64(len).bigEndian; frame.append(Data(bytes: &l, count: 8)) }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }; frame.append(contentsOf: mask)
        for (i, b) in data.enumerated() { frame.append(b ^ mask[i % 4]) }
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { err in
                if let err = err { cc.resume(throwing: err) } else { cc.resume() }
            })
        }
    }
    func recv() async throws -> Data {
        while true {
            if let frame = Self.unmask(&buf) { return frame }
            try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { d, _, _, err in
                    if let err = err { cc.resume(throwing: err); return }
                    if let d = d { self.buf.append(d) }; cc.resume()
                }
            }
        }
    }
    func close() throws { conn.send(content: Data([0x88, 0x00]), completion: .contentProcessed({ _ in })); conn.cancel() }
    private static func unmask(_ buf: inout Data) -> Data? {
        guard buf.count >= 2 else { return nil }
        let op = buf[0] & 0x0F; var plen = Int(buf[1] & 0x7F); var off = 2
        if plen == 126 { guard buf.count >= 4 else { return nil }; plen = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt16.self) }.bigEndian); off += 2 }
        else if plen == 127 { guard buf.count >= 10 else { return nil }; off += 8 }
        let masked = buf[1] & 0x80 != 0; let restLen = off + (masked ? 4 : 0) + plen
        guard buf.count >= restLen else { return nil }
        if op == 0x8 { buf.removeSubrange(0..<restLen); return Data() }
        if op == 0x9 { buf.removeSubrange(0..<restLen); return nil }
        if !masked { defer { buf.removeSubrange(0..<restLen) }; return buf.subdata(in: off..<off+plen) }
        let maskBytes = [buf[off], buf[off+1], buf[off+2], buf[off+3]]; off += 4
        var out = Data(count: plen)
        for i in 0..<plen { out[i] = buf[off+i] ^ maskBytes[i % 4] }
        buf.removeSubrange(0..<restLen); return out
    }
}
