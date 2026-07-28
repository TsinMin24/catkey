import AVFoundation
import Network
import AppKit
import CoreGraphics
import Compression
import Foundation
import CryptoKit
import zlib

// MARK: - MagicKey Voice Input Manager
// Uses 火山引擎 豆包流式语音识别2.0 WebSocket binary protocol (bigmodel)
// Reference: archibate/talky (MIT) — Python rewritten to Swift for macOS

class VoiceInputManager {
    static let shared = VoiceInputManager()

    // MARK: State
    private var audioEngine: AVAudioEngine?
    private var audioData = Data()       // raw Int16 PCM @ hardware native rate
    private var wasRecording = false

    // MARK: Credentials (UserDefaults)
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

    // MARK: Public API
    func toggleVoiceInput() {
        if wasRecording { stopAndTranscribe() } else { startRecording() }
    }
    func pressEnter() {
        simulateKeyPress(keyCode: 0x24)
    }

    // ──────────────────────────────────────────────
    //  AUDIO CAPTURE
    // ──────────────────────────────────────────────
    private func startRecording() {
        guard !wasRecording, isReady else {
            showError("请先在设置中填写火山引擎 API 凭证")
            return
        }
        log("开始录音...")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] g in
                if g { DispatchQueue.main.async { self?.startRecording() } }
            }
            return
        case .denied, .restricted:
            showError("请在 系统设置 → 隐私 → 麦克风 中允许 MagicKey")
            return
        default: break
        }

        audioData = Data()
        audioEngine = AVAudioEngine()
        audioEngine!.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            guard let self = self, let f = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            var s = [Int16](repeating: 0, count: n)
            for i in 0..<n { s[i] = Int16(max(-1, min(1, f.pointee[i])) * 32767) }
            self.audioData.append(Data(bytes: &s, count: n * 2))
        }
        do { try audioEngine!.start(); wasRecording = true; postStateNotification(true) }
        catch { showError("录音失败: \(error.localizedDescription)"); cleanup() }
    }

    private func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        wasRecording = false
        postStateNotification(false)
    }

    private func stopAndTranscribe() {
        guard wasRecording, let engine = audioEngine else { return }
        log("停止录音，开始识别...")
        let hwSampleRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        let recorded = audioData
        stopRecording()
        guard recorded.count > 16_000 else { return }

        Task.detached(priority: .userInitiated) {
            do {
                let pcm = Self.resample(int16: recorded, from: hwSampleRate, to: 16000)
                let text = try await self.runAsr(pcm: pcm)
                if !text.isEmpty {
                    await MainActor.run { self.injectText(text) }
                } else {
                    await MainActor.run { self.showError("语音识别返回空结果") }
                }
            } catch {
                await MainActor.run { self.showError("识别失败: \(error.localizedDescription)") }
            }
        }
    }

    @inline(__always)
    private static func resample(int16 data: Data, from sr: Double, to target: Double) -> Data {
        guard abs(sr - target) > 1 else { return data }
        let inCount  = data.count / 2
        let outCount = Int(Double(inCount) * target / sr)
        var out = Data(count: outCount * 2)
        let ratio = sr / target
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self)
                for i in 0..<outCount {
                    dst[i] = src[min(Int(Double(i) * ratio), inCount - 1)]
                }
            }
        }
        return out
    }

    // ──────────────────────────────────────────────
    //  Volcengine SeedASR binary WebSocket protocol
    // ──────────────────────────────────────────────
    private static let endpoint = "/api/v3/sauc/bigmodel_async"
    private static let resourceId = "volc.seedasr.sauc.duration"

    /// 4-byte header  (same as talky.py):
    /// byte0 = (version << 4) | header_size  →  0x11
    /// byte1 = (msgType << 4) | flags
    /// byte2 = (serial << 4) | compression
    /// byte3 = reserved   (0x00)
    private static func makeHeader(msgType: UInt8, flags: UInt8,
                                   serial: UInt8 = 1,   // JSON
                                   comp: UInt8 = 1) -> Data {   // GZIP
        var h = Data(repeating: 0, count: 4)
        h[0] = 0x11
        h[1] = (msgType << 4) | (flags & 0x0F)
        h[2] = ((serial & 0x0F) << 4) | (comp & 0x0F)
        return h
    }

    private func runAsr(pcm: Data) async throws -> String {
        log("连接 WebSocket: bigmodel_nostream...", level: .data)
        let connectId = UUID().uuidString
        let requestId = UUID().uuidString
        var hdrs = [
            "X-Api-App-Key":     volcengineAppKey,
            "X-Api-Access-Key":  volcengineAccessKey,
            "X-Api-Resource-Id": Self.resourceId,
            "X-Api-Request-Id":  requestId,
            "X-Api-Connect-Id":  connectId,
        ]
        // HMAC-SHA256 signature (if secret key is provided)
        let sec = volcengineSecretKey
        if !sec.isEmpty {
            let ts = String(Int(Date().timeIntervalSince1970))
            let sign = hmacSHA256(appId: volcengineAppKey, token: volcengineAccessKey, ts: ts, secret: sec)
            hdrs["X-Api-Timestamp"] = ts
            hdrs["X-Api-Signature"] = sign
            print("[VoiceInput] signature", ts, sign)
        }
        print("[VoiceInput] headers", hdrs.filter { $0.key.starts(with: "X-Api-") })

        let cli = try await ManualWS(
            host: "openspeech.bytedance.com", port: 443,
            path: "/api/v3/sauc/bigmodel_async",
            headers: hdrs,
            timeout: 60
        )
        defer { try? cli.close() }

        // 2 — config frame (type=1, flags=0, JSON+gzip)
        let cfgDict: [String: Any] = [
            "user":  ["uid": "magickey-macos"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                        "enable_ddc": false, "show_utterances": true, "result_type": "full"]
        ]
        let cfgJSON = try JSONSerialization.data(withJSONObject: cfgDict, options: [])
        guard let cfgGz = gzip(cfgJSON) else { throw NSError(domain: "V", code: 1, userInfo: [NSLocalizedDescriptionKey: "gzip cfg fail"]) }
        log("WebSocket 握手成功", level: .ok)
        log("发送配置帧 (bigmodel, seedasr)...", level: .data)
        try await cli.send(Self.makeHeader(msgType: 1, flags: 0) + Self.uint32be(UInt32(cfgGz.count)) + cfgGz)

        // 3 — ack
        let ack = try await cli.recv()
        if let err = Self.parseError(ack) {
            log("服务器拒绝配置: \(err.msg)", level: .err)
            throw NSError(domain: "Volc", code: Int(err.code), userInfo: [NSLocalizedDescriptionKey: "config rejected: \(err.msg)"])
        }
        log("配置帧 ACK 收到", level: .ok)

        log("发送音频数据 (\(pcm.count) 字节 PCM)...", level: .data)
        let chunkSize = 3200
        var offset = 0
        while offset < pcm.count {
            let end = Swift.min(offset + chunkSize, pcm.count)
            let isLast = end >= pcm.count
            let chunk  = pcm.subdata(in: offset..<end)
            guard let gz = gzip(chunk) else { throw NSError(domain: "V", code: 2, userInfo: [NSLocalizedDescriptionKey: "gzip audio fail"]) }
            let flags: UInt8 = isLast ? 2 : 0          // bit1 = last
            try await cli.send(Self.makeHeader(msgType: 2, flags: flags) + Self.uint32be(UInt32(gz.count)) + gz)
            offset = end
        }

        // 5 — receive results until last frame
        log("等待语音识别结果...", level: .data)
        var finalText = ""
        while true {
            let raw  = try await cli.recv()
            guard raw.count >= 4 else { continue }
            let msgType = raw[1] >> 4
            let flags   = raw[1] & 0x0F
            let compressed = (raw[2] & 0x0F) == 1
            var off = 4
            if (flags & 1) != 0 { off += 4 }

            if msgType == 0x0F {
                let code = raw.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
                let sz   = raw.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
                var body = raw.subdata(in: off..<off+Int(sz))
                if compressed { body = VoiceInputManager.gunzip(body) ?? body }
                throw NSError(domain: "Volc", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "api error: \(String(data: body, encoding: .utf8) ?? "?")"])
            }

            let sz = raw.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
            var body = raw.subdata(in: off..<off+Int(sz))
            if compressed { body = VoiceInputManager.gunzip(body) ?? body }

            if msgType == 0x09,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let text = result["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    finalText = trimmed
                    log("识别结果: \"\(trimmed)\"", level: .data)
                    // 流式注入中间结果到当前光标处
                    await MainActor.run { self.injectOverlay(trimmed) }
                }
            }
            if (flags & 2) != 0 {
                log("语音识别完成", level: .ok)
                break
            }
        }
        return finalText
    }

    // ──────────────────────────────────────────────
    //  utility: gzip, gunzip, big-endian helpers
    // ──────────────────────────────────────────────
    private static func parseError(_ data: Data) -> (code: UInt32, msg: String)? {
        guard data.count >= 4, data[1] >> 4 == 0x0F else { return nil }
        let compressed = (data[2] & 0x0F) == 1
        var off = 4
        let code = data.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
        let sz   = data.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
        var body = data.subdata(in: off..<off+Int(sz))
        if compressed { body = VoiceInputManager.gunzip(body) ?? body }
        return (code, String(data: body, encoding: .utf8) ?? "?")
    }

    private func gzip(_ data: Data) -> Data? {
        guard let raw = rawDeflate(data) else { return nil }
        let hdr: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff]
        let crc = data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> UInt32 in
            UInt32(crc32(0, rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(data.count)))
        }
        var trailer = Data()
        var crcLE = crc.littleEndian
        var isize = UInt32(data.count).littleEndian
        trailer.append(Data(bytes: &crcLE, count: 4))
        trailer.append(Data(bytes: &isize, count: 4))
        return Data(hdr) + raw + trailer
    }

    private func rawDeflate(_ data: Data) -> Data? {
        let cap = 64 + data.count + data.count / 4
        var dst = Data(count: cap)
        let wr = dst.withUnsafeMutableBytes { dstPtr in
            data.withUnsafeBytes { srcPtr in
                compression_encode_buffer(dstPtr.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          srcPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard wr > 0 else { return nil }
        return dst.prefix(wr)
    }

    private static func gunzip(_ data: Data) -> Data? {
        let step = 256 * 1024
        var total = Data()
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            var srcPtr = src.baseAddress!
            var avail = data.count
            while avail > 0 {
                var dstBuf = [UInt8](repeating: 0, count: step)
                let wr = compression_decode_buffer(&dstBuf, step, srcPtr, avail, nil, COMPRESSION_ZLIB)
                guard wr > 0 else { return }
                total.append(contentsOf: dstBuf.prefix(wr))
                srcPtr += (avail - (avail - wr))
                avail -= (avail - wr)
            }
        }
        return total.isEmpty ? nil : total
    }

    private static func uint32be(_ v: UInt32) -> Data {
        var v = v.bigEndian
        return Data(bytes: &v, count: 4)
    }

    // HMAC-SHA256 signature for volcengine seeded asr
    private func hmacSHA256(appId: String, token: String, ts: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        guard let msgData = (appId + token + ts).data(using: .utf8) else { return "" }
        let code = HMAC<SHA256>.authenticationCode(for: msgData, using: key)
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    // ──────────────────────────────────────────────
    //  Text injection
    // ──────────────────────────────────────────────

    // 流式注入中间结果：用 unicode event 直接打字（不通过剪贴板）
    private var lastPartial = ""
    private func injectOverlay(_ text: String) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        // 增量注入：只打新字符
        if text.hasPrefix(lastPartial) {
            let delta = String(text.dropFirst(lastPartial.count))
            for ch in delta.unicodeScalars {
                let u = ch.value
                if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(truncatingIfNeeded: u)])
                    down.post(tap: .cgAnnotatedSessionEventTap)
                }
                if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                    up.post(tap: .cgAnnotatedSessionEventTap)
                }
            }
        } else {
            // 全量替换：删旧文本 + 打新文本
            injectText(text)
        }
        lastPartial = text
    }

    private func injectText(_ text: String) {
        // 先选中所有 + 退格清空 + 粘贴
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        for (kc, down, fl) in [(0x38 as CGKeyCode, true,  CGEventFlags()),
                                (0x09, true,  CGEventFlags.maskCommand),
                                (0x09, false, CGEventFlags.maskCommand),
                                (0x38, false, CGEventFlags())] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: down) {
                e.flags = fl; e.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    private func simulateKeyPress(keyCode: CGKeyCode) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        for d in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: d) {
                e.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    // MARK: helpers
    private func showError(_ msg: String) {
        LogManager.shared.append(msg, level: .err)
        let a = NSAlert(); a.messageText = msg; a.runModal()
    }
    private func log(_ msg: String, level: LogManager.Level = .info) {
        LogManager.shared.append(msg, level: level)
    }
    private func postStateNotification(_ r: Bool) {
        NotificationCenter.default.post(name: Notification.Name("voiceRecordingStateChanged"), object: r)
    }
    private func cleanup() {
        audioEngine = nil; wasRecording = false; postStateNotification(false)
    }
}

// MARK: - Manual WebSocket client (NWConnection + manual HTTP upgrade)
private class ManualWS {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "ws")
    private var buf = Data()

    init(host: String, port: UInt16, path: String,
         headers: [String: String], timeout: TimeInterval) async throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        var req = "GET \(path) HTTP/1.1\r\n"
        req += "Host: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        req += "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (k,v) in headers { req += "\(k): \(v)\r\n" }
        req += "\r\n"

        self.conn = NWConnection(to: .hostPort(host: NWEndpoint.Host(host),
                                                port: NWEndpoint.Port(rawValue: port)!), using: .tls)
        conn.start(queue: queue)

        // send upgrade, read response
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            conn.stateUpdateHandler = { [weak conn] st in
                guard st == .ready, let c = conn else { return }
                c.send(content: Data(req.utf8), completion: .contentProcessed { err in
                    if let err = err { cc.resume(throwing: err); return }
                    c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { d, _, _, err in
                        if let err = err { cc.resume(throwing: err); return }
                        let resp = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        if resp.contains("101 Switching Protocols") || resp.contains("101") {
                            cc.resume()
                        } else {
                            cc.resume(throwing: NSError(domain: "WS", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "handshake failed: \(resp.prefix(200))"]))
                        }
                    }
                })
            }
        }
    }

    func send(_ data: Data) async throws {
        // wrap in WebSocket binary frame (masked client→server)
        var frame = Data([0x82])  // FIN + binary opcode
        let len = data.count
        if len < 126 {
            frame.append(UInt8(0x80 | UInt8(len)))
        } else if len < 65536 {
            frame.append(contentsOf: [UInt8(0x80 | 126)])
            var l = UInt16(len).bigEndian; frame.append(Data(bytes: &l, count: 2))
        } else {
            frame.append(contentsOf: [UInt8(0x80 | 127)])
            var l = UInt64(len).bigEndian; frame.append(Data(bytes: &l, count: 8))
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        for (i, b) in data.enumerated() { frame.append(b ^ mask[i % 4]) }

        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            conn.send(content: frame, completion: .contentProcessed { err in
                if let err = err { cc.resume(throwing: err) } else { cc.resume() }
            })
        }
    }

    func recv() async throws -> Data {
        // accumulate until we have a complete WebSocket frame
        while true {
            if let frame = Self.unmaskFromBuffer(&buf) { return frame }
            try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { d, _, _, err in
                    if let err = err { cc.resume(throwing: err); return }
                    if let d = d { self.buf.append(d) }
                    cc.resume()
                }
            }
        }
    }

    func close() throws {
        // send close frame
        conn.send(content: Data([0x88, 0x00]), completion: .contentProcessed({ _ in }))
        conn.cancel()
    }

    private static func unmaskFromBuffer(_ buf: inout Data) -> Data? {
        guard buf.count >= 2 else { return nil }
        let op = buf[0] & 0x0F
        let masked = buf[1] & 0x80 != 0
        var plen = Int(buf[1] & 0x7F)
        var off = 2
        if plen == 126 { guard buf.count >= 4 else { return nil }; plen = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt16.self) }.bigEndian); off += 2 }
        else if plen == 127 { guard buf.count >= 10 else { return nil }; off += 8 }
        let restLen = off + (masked ? 4 : 0) + plen
        guard buf.count >= restLen else { return nil }

        // handle control frames
        if op == 0x8 { buf.removeSubrange(0..<restLen); return Data() }
        if op == 0x9 { /* ping */ buf.removeSubrange(0..<restLen); return nil }

        if !masked {
            defer { buf.removeSubrange(0..<restLen) }
            return buf.subdata(in: off..<off+plen)
        }
        let mask = [buf[off], buf[off+1], buf[off+2], buf[off+3]]; off += 4
        var out = Data(count: plen)
        for i in 0..<plen { out[i] = buf[off+i] ^ mask[i % 4] }
        buf.removeSubrange(0..<restLen)
        return out
    }
}
