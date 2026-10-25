import AVFoundation
import Compression
import Network
import AppKit
import CoreGraphics
import Foundation
import zlib

/// 语音识别管理器：F20 按住说话 / 松开即停，Volcengine SeedASR 流式识别，
/// 文字通过 CGEvent 逐字注入当前光标位置（带退格修正）。
///
/// 线程模型：
/// - `stateLock` 保护 `wasRecording / stopRequested / micBuf / micSeq`
/// - `injectQueue` 串行执行所有文字注入（部分结果 + 最终结果），
///   避免在主线程 usleep 导致 UI 冻结
class VoiceInputManager {
    static let shared = VoiceInputManager()

    private var audioEngine: AVAudioEngine?
    private var streamTask: Task<Void, Never>?
    private var sendTask: Task<Void, Error>?
    private var recvTask: Task<Void, Error>?
    private var wsConnection: NWConnection?
    private var stopWatchdog: Task<Void, Never>?
    private var currentSampleRate: Double = 44100

    private let stateLock = NSLock()
    private var wasRecording = false
    private var stopRequested = false
    private var micBuf = Data()
    private var micSeq: Int32 = 2
    private var audioMeterChunks = 0

    /// 文字注入专用串行队列（typedText 只允许在该队列上访问）
    private let injectQueue = DispatchQueue(label: "magickey.inject")
    private var injectBusy = false
    private var typedText = ""

    private var latestText = ""
    private var lastToggleTime: Date = .distantPast
    private let defaults = UserDefaults.standard

    // MARK: - 供应商与识别模式

    private enum CaptureKind {
        case volcengine        // 火山：现有 WS 流式协议
        case qwenRealtime      // Qwen：WebSocket 实时
        case qwenFile          // Qwen：整段 HTTP
        case mimoStream        // MiMo：整段上传 + SSE 边返回边出字
        case mimoFile          // MiMo：整段 HTTP
    }

    private var activeKind: CaptureKind = .volcengine
    private var injectPartials = true
    private var qwenSession: QwenRealtimeSession?

    var asrProvider: ASRProvider {
        get { ASRSettings.provider }
        set { ASRSettings.provider = newValue }
    }
    var asrMode: ASRMode {
        get { ASRSettings.mode }
        set { ASRSettings.mode = newValue }
    }

    /// New Volcengine console authentication: one API Key only.
    var volcengineAPIKey: String {
        get { defaults.string(forKey: "VolcengineAPIKey") ?? "" }
        set { defaults.set(newValue, forKey: "VolcengineAPIKey") }
    }
    var volcengineResourceId: String {
        get { defaults.string(forKey: "VolcengineResourceId") ?? "volc.seedasr.sauc.duration" }
        set { defaults.set(newValue, forKey: "VolcengineResourceId") }
    }
    var isReady: Bool { !ASRSettings.apiKey(for: ASRSettings.provider).isEmpty }

    func toggleVoiceInput() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) >= 0.5 else { return }
        lastToggleTime = now
        if isRecording() {
            stopVoiceInput()
        } else {
            startVoiceInput()
        }
    }

    /// Push-to-talk：按下时按当前供应商/模式开始录音与识别
    func startVoiceInput() {
        guard !isRecording() else { return }
        let provider = ASRSettings.provider
        let mode = ASRSettings.mode
        guard isReady else {
            showError("请先填写 \(provider.displayName) 的 API Key")
            return
        }
        ensureMicAccess { [weak self] in
            guard let self = self else { return }
            switch (provider, mode) {
            case (.volcengine, _):
                self.startStreaming()
            case (.qwen, .streaming):
                self.startQwenStreaming()
            case (.qwen, .file):
                self.startFileCapture(provider: .qwen)
            case (.mimo, .streaming):
                self.startMiMoStreaming()
            case (.mimo, .file):
                self.startFileCapture(provider: .mimo)
            }
        }
    }

    private func ensureMicAccess(_ then: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted { DispatchQueue.main.async { then() } }
            }
        case .denied, .restricted:
            showError("请允许麦克风权限")
        default:
            then()
        }
    }

    /// Push-to-talk：松开时停止采集。流式进入“flush + 结束帧”收尾，
    /// 非流式则把整段音频上传后一次性出字（最长 8 秒兜底）
    func stopVoiceInput() {
        stateLock.lock()
        guard wasRecording else { stateLock.unlock(); return }
        stopRequested = true
        let engine = audioEngine
        let kind = activeKind
        let session = qwenSession
        stateLock.unlock()

        // 立即停止采集，不再产生新音频
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        postStateNotification(false)

        switch kind {
        case .volcengine:
            log("停止录音…（等待服务端收尾）", level: .info)
        case .qwenRealtime:
            log("停止录音…（等待服务端收尾）", level: .info)
            Task { [weak self] in
                await session?.finish()
                await MainActor.run { self?.stopEverything() }
            }
        case .qwenFile, .mimoFile, .mimoStream:
            log("停止录音…（上传识别中）", level: .info)
            finishFileCapture(kind)
        }

        // 兜底：服务端迟迟不回最终结果时强制清理
        stopWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run { self?.forceCleanupIfStuck() }
        }
    }

    func isRecording() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wasRecording
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    private func forceCleanupIfStuck() {
        if isRecording() {
            stopEverything()
        }
    }

    // MARK: - 录音主流程

    private func beginSession(_ label: String) {
        stateLock.lock()
        wasRecording = true
        stopRequested = false
        micBuf.removeAll()
        micSeq = 2
        audioMeterChunks = 0
        stateLock.unlock()

        latestText = ""
        injectQueue.async { [weak self] in
            guard let self = self else { return }
            self.typedText = ""
            self.injectBusy = false
        }

        log(label)
        postStateNotification(true)
    }

    private func startStreaming() {
        guard !isRecording() else { return }
        activeKind = .volcengine
        // 非流式模式下仍走 WS 传输，但只在收到最终结果时出字
        injectPartials = (ASRSettings.mode == .streaming)
        beginSession("开始录音…")

        let engine = AVAudioEngine()
        audioEngine = engine
        // 用输入设备真实采样率（可能是 44.1k 或 48k），不要写死
        let sr = engine.inputNode.outputFormat(forBus: 0).sampleRate
        currentSampleRate = (sr > 8000) ? sr : 44100
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        let captureDevice = AVCaptureDevice.default(for: .audio)
        let deviceName = captureDevice?.localizedName ?? "未能读取设备名称"
        let deviceID = captureDevice?.uniqueID ?? "未知 ID"
        log("录音输入设备：\(deviceName)（ID: \(deviceID)）", level: .ok)
        log(String(format: "输入格式：%.0f Hz / %d 声道；引擎输出：%.0f Hz", inputFormat.sampleRate, inputFormat.channelCount, sr), level: .info)

        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                try await self.runStream(engine: engine)
            } catch {
                await MainActor.run {
                    if self.isRecording() {
                        self.log("错误: \(error.localizedDescription)", level: .err)
                    }
                    self.stopEverything()
                }
            }
        }
    }

    // MARK: - Qwen / MiMo / 非流式路径

    /// 建立录音引擎，把每块 PCM16（设备原始采样率、单声道）交给 feed。
    /// 音量峰值日志与声道选择逻辑和火山路径保持一致。
    @discardableResult
    private func beginCapture(_ feed: @escaping (Data) -> Void) -> Bool {
        let engine = AVAudioEngine()
        audioEngine = engine
        let sr = engine.inputNode.outputFormat(forBus: 0).sampleRate
        currentSampleRate = (sr > 8000) ? sr : 44100

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        let captureDevice = AVCaptureDevice.default(for: .audio)
        log("录音输入设备：\(captureDevice?.localizedName ?? "未能读取设备名称")（ID: \(captureDevice?.uniqueID ?? "未知 ID")）", level: .ok)
        log(String(format: "输入格式：%.0f Hz / %d 声道；引擎输出：%.0f Hz", inputFormat.sampleRate, inputFormat.channelCount, currentSampleRate), level: .info)

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            guard let self = self, let f = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            // 部分 USB 接收器只在一路声道输出声音，取能量最大的那一路
            let ch = max(Int(buf.format.channelCount), 1)
            var use = 0
            if ch > 1 {
                var best: Float = -1
                for c in 0..<ch {
                    var p: Float = 0
                    for i in 0..<n { p = max(p, abs(f[c][i])) }
                    if p > best { best = p; use = c }
                }
            }
            let src = f[use]
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(src[i])) }
            self.stateLock.lock()
            self.audioMeterChunks += 1
            let meterCount = self.audioMeterChunks
            self.stateLock.unlock()
            if meterCount == 1 || meterCount % 20 == 0 {
                self.log(String(format: "录音帧：%d，音量峰值：%.4f%@（声道 %d/%d）", meterCount, peak, peak < 0.002 ? "（接近静音）" : "", use + 1, ch), level: peak < 0.002 ? .err : .info)
            }
            var s = [Int16](repeating: 0, count: n)
            for i in 0..<n { s[i] = Int16(max(-1, min(1, src[i])) * 32767) }
            feed(Data(bytes: &s, count: n * 2))
        }

        do {
            try engine.start()
            return true
        } catch {
            showError("启动录音失败：\(error.localizedDescription)")
            return false
        }
    }

    private func startQwenStreaming() {
        guard !isRecording() else { return }
        guard let url = URL(string: ASRSettings.qwenRealtimeURL) else {
            showError("Qwen 实时接口地址无效")
            return
        }
        activeKind = .qwenRealtime
        injectPartials = true
        beginSession("开始录音…（Qwen 实时）")

        let session = QwenRealtimeSession(apiKey: ASRSettings.qwenAPIKey, url: url, language: ASRSettings.language)
        qwenSession = session

        guard beginCapture({ [weak self] chunk in
            guard let self = self else { return }
            let pcm = ASRUtil.resample(chunk, from: self.currentSampleRate, to: 16000)
            Task { await session.appendPCM(pcm) }
        }) else {
            stopEverything()
            return
        }

        Task { [weak self] in
            do {
                try await session.start(
                    onPartial: { text in
                        DispatchQueue.main.async { self?.handlePartialResult(text) }
                    },
                    onFinal: { text in
                        DispatchQueue.main.async { self?.latestText = text }
                    },
                    onError: { message in
                        DispatchQueue.main.async { self?.showError("Qwen: \(message)") }
                    }
                )
            } catch {
                DispatchQueue.main.async {
                    self?.showError("Qwen 连接失败：\(error.localizedDescription)")
                    self?.stopEverything()
                }
            }
        }
    }

    /// MiMo 只有整段接口：这里只录音，松手后带 SSE 上传，边返回边出字
    private func startMiMoStreaming() {
        guard !isRecording() else { return }
        activeKind = .mimoStream
        injectPartials = true
        beginSession("开始录音…（MiMo，整段上传）")
        guard beginCapture({ [weak self] chunk in
            guard let self = self else { return }
            self.stateLock.lock()
            self.micBuf.append(chunk)
            self.stateLock.unlock()
        }) else {
            stopEverything()
            return
        }
    }

    private func startFileCapture(provider: ASRProvider) {
        guard !isRecording() else { return }
        activeKind = (provider == .qwen) ? .qwenFile : .mimoFile
        injectPartials = false
        beginSession("开始录音…（\(provider.displayName) 非流式）")
        guard beginCapture({ [weak self] chunk in
            guard let self = self else { return }
            self.stateLock.lock()
            self.micBuf.append(chunk)
            self.stateLock.unlock()
        }) else {
            stopEverything()
            return
        }
    }

    /// 非流式收尾：整段音频转 16k 单声道 WAV 后上传，拿到最终文本再一次性注入
    private func finishFileCapture(_ kind: CaptureKind) {
        stateLock.lock()
        let buf = micBuf
        micBuf.removeAll()
        let sr = currentSampleRate
        stateLock.unlock()

        let pcm16k = ASRUtil.resample(buf, from: sr, to: 16000)
        guard !pcm16k.isEmpty else {
            showError("没有录到音频")
            stopEverything()
            return
        }
        let wav = ASRUtil.wav(fromPCM16: pcm16k, sampleRate: 16000)
        log(String(format: "音频长度 %.1f 秒，上传识别…（%.0f KB）",
                   Double(pcm16k.count / 2) / 16000.0,
                   Double(wav.count) / 1024.0), level: .info)

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let text: String
                switch kind {
                case .qwenFile:
                    guard let url = URL(string: ASRSettings.qwenHTTPURL) else {
                        throw NSError(domain: "Qwen", code: -1, userInfo: [NSLocalizedDescriptionKey: "Qwen 接口地址无效"])
                    }
                    text = try await QwenFileASR.transcribe(
                        wav: wav, apiKey: ASRSettings.qwenAPIKey, endpoint: url,
                        model: ASRSettings.qwenModel, language: ASRSettings.language)
                case .mimoFile:
                    guard let url = URL(string: ASRSettings.mimoURL) else {
                        throw NSError(domain: "MiMo", code: -1, userInfo: [NSLocalizedDescriptionKey: "MiMo 接口地址无效"])
                    }
                    text = try await MiMoASR.transcribe(
                        wav: wav, apiKey: ASRSettings.mimoAPIKey, endpoint: url,
                        model: ASRSettings.mimoModel, language: ASRSettings.language,
                        auth: ASRSettings.mimoAuth)
                case .mimoStream:
                    guard let url = URL(string: ASRSettings.mimoURL) else {
                        throw NSError(domain: "MiMo", code: -1, userInfo: [NSLocalizedDescriptionKey: "MiMo 接口地址无效"])
                    }
                    text = try await MiMoASR.transcribeStreaming(
                        wav: wav, apiKey: ASRSettings.mimoAPIKey, endpoint: url,
                        model: ASRSettings.mimoModel, language: ASRSettings.language,
                        auth: ASRSettings.mimoAuth,
                        onPartial: { partial in
                            DispatchQueue.main.async { self.handlePartialResult(partial) }
                        })
                default:
                    text = ""
                }
                await MainActor.run {
                    self.latestText = text
                    self.log("识别完成：\(text.prefix(60))", level: .ok)
                    self.stopEverything()
                }
            } catch {
                await MainActor.run {
                    self.showError("识别失败：\(error.localizedDescription)")
                    self.stopEverything()
                }
            }
        }
    }

    private func runStream(engine: AVAudioEngine) async throws {
        let hdrs = [
            "X-Api-Key": volcengineAPIKey,
            "X-Api-Resource-Id": volcengineResourceId,
            "X-Api-Request-Id": UUID().uuidString,
            "X-Api-Connect-Id": UUID().uuidString,
        ]
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
        guard let gz = gzipData(cfgJSON) else {
            throw NSError(domain: "V", code: 1, userInfo: [NSLocalizedDescriptionKey: "gzip config failed"])
        }
        try await ws.send(cfgFrame(gz))
        let ack = try await ws.recv()
        await log("配置 ACK (\(ack.count)B)", level: .ok)

        let sTask = Task<Void, Error> { [weak self] in
            guard let self = self else { return }
            let ok: Bool = await MainActor.run {
                // 松开发生在这之前：跳过采集，直接进入收尾
                guard !self.isStopped() else { return false }
                engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
                    guard let self = self, let f = buf.floatChannelData else { return }
                    let n = Int(buf.frameLength)
                    // 部分 USB 接收器只在一路声道输出声音，取能量最大的那一路
                    let ch = max(Int(buf.format.channelCount), 1)
                    var use = 0
                    if ch > 1 {
                        var best: Float = -1
                        for c in 0..<ch {
                            var p: Float = 0
                            for i in 0..<n { p = max(p, abs(f[c][i])) }
                            if p > best { best = p; use = c }
                        }
                    }
                    let src = f[use]
                    var peak: Float = 0
                    for i in 0..<n { peak = max(peak, abs(src[i])) }
                    self.stateLock.lock()
                    self.audioMeterChunks += 1
                    let meterCount = self.audioMeterChunks
                    self.stateLock.unlock()
                    if meterCount == 1 || meterCount % 20 == 0 {
                        self.log(String(format: "录音帧：%d，音量峰值：%.4f%@（声道 %d/%d）", meterCount, peak, peak < 0.002 ? "（接近静音）" : "", use + 1, ch), level: peak < 0.002 ? .err : .info)
                    }
                    var s = [Int16](repeating: 0, count: n)
                    for i in 0..<n { s[i] = Int16(max(-1, min(1, src[i])) * 32767) }
                    let raw = Data(bytes: &s, count: n * 2)
                    let sr = self.currentSampleRate
                    Task { await self.sendMicChunk(raw, ws: ws, sampleRate: sr) }
                }
                do { try engine.start() } catch { return false }
                return true
            }
            if ok {
                while !Task.isCancelled {
                    if self.isStopped() { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            // 关键：先 flush 剩余音频，再发负序号结束帧，服务端才会出最终结果
            await self.flushAndSendFinal(ws: ws)
            await MainActor.run {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        await MainActor.run { self.sendTask = sTask }

        let rTask = Task<Void, Error> { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                let raw: Data
                do { raw = try await ws.recv() }
                catch {
                    await self.log("WS 接收结束: \(error.localizedDescription)", level: .info)
                    break
                }
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
                    let errMsg = raw.count >= off + Int(msgSize) ? String(data: raw.subdata(in: off..<off + Int(msgSize)), encoding: .utf8) ?? "?" : "?"
                    await self.log("API错误 [\(errCode)]: \(errMsg)", level: .err)
                    break
                }

                if mt == 0x09 {
                    guard raw.count >= off + 4 else { continue }
                    let sz = raw.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.bigEndian; off += 4
                    guard raw.count >= off + Int(sz) else { continue }
                    var b = raw.subdata(in: off..<off + Int(sz))
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
        _ = try? await rTask.result

        await MainActor.run { self.stopEverything() }
    }

    // MARK: - 音频发送与收尾

    private func sendMicChunk(_ raw: Data, ws: ManualWS, sampleRate: Double) async {
        stateLock.lock()
        guard wasRecording else { stateLock.unlock(); return }
        micBuf.append(raw)
        var chunks: [(Data, Int32)] = []
        while micBuf.count >= 3200 {
            let chunk = micBuf.prefix(3200)
            micBuf.removeFirst(min(3200, micBuf.count))
            chunks.append((Data(chunk), micSeq))
            micSeq += 1
        }
        stateLock.unlock()

        for (chunk, _) in chunks {
            let pcm16k = resample(int16: chunk, from: sampleRate, to: 16000)
            // Non-empty audio packets remain gzip-compressed. This is the
            // framing that produced realtime recognition reliably. The EOF
            // issue was caused only by marking an empty final packet gzip.
            guard let gz = gzipData(pcm16k) else { return }
            var h = Data([0x11, 0x20, 0x01, 0x00])
            var sz = UInt32(gz.count).bigEndian; h.append(Data(bytes: &sz, count: 4))
            h.append(gz)
            do { try await ws.send(h) } catch { return }
        }
    }

    /// 停止时调用：发送剩余音频（若有），然后发送负序号结束帧
    private func flushAndSendFinal(ws: ManualWS) async {
        stateLock.lock()
        let buf = micBuf
        micBuf.removeAll()
        stateLock.unlock()

        if !buf.isEmpty {
            let pcm16k = resample(int16: buf, from: currentSampleRate, to: 16000)
            if let gz = gzipData(pcm16k) {
                var h = Data([0x11, 0x20, 0x01, 0x00])
                var sz = UInt32(gz.count).bigEndian; h.append(Data(bytes: &sz, count: 4))
                h.append(gz)
                try? await ws.send(h)
            }
        }

        // Final audio-only request: flag 0x2 marks the last packet. There is
        // no sequence field in the client audio frame; the payload is empty
        // when all buffered audio was already flushed above.
        // The empty final frame must also be uncompressed; marking an empty
        // payload as gzip makes the server attempt to gunzip zero bytes.
        var h = Data([0x11, 0x22, 0x00, 0x00])
        var sz = UInt32(0).bigEndian; h.append(Data(bytes: &sz, count: 4))
        try? await ws.send(h)
    }

    private func cfgFrame(_ payload: Data) -> Data {
        var h = Data([0x11, 0x10, 0x11, 0x00])
        var sz = UInt32(payload.count).bigEndian; h.append(Data(bytes: &sz, count: 4))
        h.append(payload)
        return h
    }

    // MARK: - 清理（主线程）

    private func stopEverything() {
        stateLock.lock()
        guard wasRecording else { stateLock.unlock(); return }
        wasRecording = false
        stopRequested = false
        stateLock.unlock()

        stopWatchdog?.cancel()
        stopWatchdog = nil
        postStateNotification(false)
        log("停止录音…")

        wsConnection?.cancel()
        wsConnection = nil
        qwenSession?.close()
        qwenSession = nil
        recvTask?.cancel()
        sendTask?.cancel()
        streamTask?.cancel()
        recvTask = nil
        sendTask = nil
        streamTask = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        stateLock.lock()
        micBuf.removeAll()
        micSeq = 2
        stateLock.unlock()

        // 最终文字补全（含未注入的剩余部分）
        finalizeInjection(latestText)
        latestText = ""
        log("已停止")
    }

    // MARK: - 流式注入（串行队列，退格修正）

    private func handlePartialResult(_ newFullText: String) {
        latestText = newFullText
        guard injectPartials else { return }
        let trimmed = newFullText.trimmingCharacters(in: .whitespacesAndNewlines)
        injectQueue.async { [weak self] in
            guard let self = self else { return }
            // 正在注入或已停止：丢弃过期部分结果，最终结果会补全
            guard !self.injectBusy, !self.isStopped() else { return }
            self.injectBusy = true
            defer { self.injectBusy = false }
            self.applyCorrection(to: trimmed)
        }
    }

    private func finalizeInjection(_ finalText: String) {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        injectQueue.async { [weak self] in
            guard let self = self else { return }
            self.injectBusy = false
            self.applyCorrection(to: trimmed)
            self.typedText = trimmed
        }
    }

    /// 把窗口内容修正到 target：最长公共前缀保留，退格删除差异后缀，再输入新后缀
    private func applyCorrection(to target: String) {
        let cp = commonPrefixLen(typedText, target)
        let deleteCount = typedText.count - cp
        let suffixIdx = target.index(target.startIndex, offsetBy: cp)
        let suffix = String(target[suffixIdx...])
        typeChars(backspaces: deleteCount, then: suffix)
        typedText = target
    }

    private func typeChars(backspaces: Int, then text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        if backspaces > 0 {
            let backspace: CGKeyCode = 0x33
            for _ in 0..<backspaces {
                if let down = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: true) { down.post(tap: .cghidEventTap) }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: false) { up.post(tap: .cghidEventTap) }
                usleep(1000)
            }
        }
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
            usleep(1000)
        }
    }

    private func commonPrefixLen(_ a: String, _ b: String) -> Int {
        let (s1, s2) = (Array(a), Array(b))
        var i = 0
        while i < s1.count && i < s2.count && s1[i] == s2[i] { i += 1 }
        return i
    }

    // MARK: - Gzip / 重采样

    private func gzipData(_ data: Data) -> Data? {
        guard let raw = rawDeflate(data) else { return nil }
        let hdr: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff]
        let crc = UInt32(crc32(0, data.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress }, uInt(data.count)))
        var trailer = Data()
        var crcLE = crc.littleEndian; trailer.append(Data(bytes: &crcLE, count: 4))
        var isize = UInt32(data.count).littleEndian; trailer.append(Data(bytes: &isize, count: 4))
        return Data(hdr) + raw + trailer
    }

    private func rawDeflate(_ data: Data) -> Data? {
        let cap = 64 + data.count + data.count / 4
        var dst = Data(count: cap)
        let wr = dst.withUnsafeMutableBytes { d in data.withUnsafeBytes { s in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
                                      s.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        } }
        return wr > 0 ? dst.prefix(wr) : nil
    }

    private static func gunzipData(_ data: Data) -> Data? {
        let step = 256 * 1024
        var total = Data()
        data.withUnsafeBytes { raw in
            var p = raw.bindMemory(to: UInt8.self).baseAddress!
            var avail = data.count
            while avail > 0 {
                var buf = [UInt8](repeating: 0, count: step)
                let wr = compression_decode_buffer(&buf, step, p, avail, nil, COMPRESSION_ZLIB)
                guard wr > 0 else { return }
                total.append(contentsOf: buf.prefix(wr))
                p += wr
                avail -= wr
            }
        }
        return total.isEmpty ? nil : total
    }

    private func resample(int16 data: Data, from sr: Double, to target: Double) -> Data {
        guard abs(sr - target) > 1 else { return data }
        let inCount = data.count / 2
        let outCount = Int(Double(inCount) * target / sr)
        var out = Data(count: outCount * 2)
        let ratio = sr / target
        data.withUnsafeBytes { r in
            let src = r.bindMemory(to: Int16.self)
            out.withUnsafeMutableBytes { r in
                let dst = r.bindMemory(to: Int16.self)
                for i in 0..<outCount {
                    dst[i] = src[min(Int(Double(i) * ratio), inCount - 1)]
                }
            }
        }
        return out
    }

    // MARK: - 工具

    /// 非阻塞错误提示：写入日志即可，避免 runModal 卡主线程
    private func showError(_ msg: String) {
        LogManager.shared.append(msg, level: .err)
    }

    private func log(_ msg: String, level: LogManager.Level = .info) {
        DispatchQueue.main.async { LogManager.shared.append(msg, level: level) }
    }

    private func postStateNotification(_ r: Bool) {
        NotificationCenter.default.post(name: NSNotification.Name("voiceRecordingStateChanged"), object: r)
    }
}

// MARK: - ManualWS（自实现 WebSocket 客户端）

private class ManualWS {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "ws")
    private var buf = Data()

    var underlyingConnection: NWConnection { conn }

    init(host: String, port: UInt16, path: String, headers: [String: String], timeout: TimeInterval) async throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        req += "\r\n"
        conn = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), using: .tls)
        conn.start(queue: queue)

        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            var resumed = false
            func resume(_ result: Result<Void, Error>) {
                guard !resumed else { return }
                resumed = true
                cc.resume(with: result)
            }

            // 超时兜底：防止服务端无响应时永久挂起
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.conn.cancel()
                resume(.failure(NSError(domain: "WS", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: "连接超时（\(Int(timeout))s）"])))
            }

            conn.stateUpdateHandler = { [weak conn] st in
                switch st {
                case .ready:
                    guard let c = conn else {
                        resume(.failure(Self.connClosed()))
                        return
                    }
                    c.send(content: Data(req.utf8), completion: .contentProcessed { err in
                        if let err = err {
                            resume(.failure(err))
                            return
                        }
                        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { d, _, _, err in
                            if let err = err {
                                resume(.failure(err))
                                return
                            }
                            guard let d = d else {
                                resume(.failure(Self.connClosed()))
                                return
                            }
                            let resp = String(data: d, encoding: .utf8) ?? ""
                            if resp.contains("101") {
                                resume(.success(()))
                            } else {
                                resume(.failure(NSError(domain: "WS", code: -1,
                                                        userInfo: [NSLocalizedDescriptionKey: "握手失败: \(resp.prefix(200))"])))
                            }
                        }
                    })
                case .failed(let err):
                    resume(.failure(err))
                case .cancelled:
                    resume(.failure(Self.connClosed()))
                case .waiting:
                    // 网络暂不可用：保持等待，由超时兜底
                    break
                @unknown default:
                    break
                }
            }
        }
        // 握手完成后不再需要状态回调
        conn.stateUpdateHandler = nil
    }

    func send(_ data: Data) async throws {
        var frame = Data([0x82])
        let len = data.count
        if len < 126 {
            frame.append(UInt8(0x80 | UInt8(len)))
        } else if len < 65536 {
            frame.append(contentsOf: [UInt8(0x80 | 126)])
            var l = UInt16(len).bigEndian
            frame.append(Data(bytes: &l, count: 2))
        } else {
            frame.append(contentsOf: [UInt8(0x80 | 127)])
            var l = UInt64(len).bigEndian
            frame.append(Data(bytes: &l, count: 8))
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        for (i, b) in data.enumerated() { frame.append(b ^ mask[i % 4]) }
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            var resumed = false
            func resume(_ result: Result<Void, Error>) {
                guard !resumed else { return }
                resumed = true
                cc.resume(with: result)
            }
            conn.send(content: frame, completion: .contentProcessed { err in
                if let err = err { resume(.failure(err)) } else { resume(.success(())) }
            })
        }
    }

    func recv() async throws -> Data {
        while true {
            if let frame = try Self.unmask(&buf) { return frame }
            try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
                var resumed = false
                func done() {
                    guard !resumed else { return }
                    resumed = true
                    cc.resume()
                }
                func fail(_ err: Error) {
                    guard !resumed else { return }
                    resumed = true
                    cc.resume(throwing: err)
                }
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { d, _, _, err in
                    if let err = err {
                        fail(err)
                        return
                    }
                    guard let d = d else {
                        fail(Self.connClosed())
                        return
                    }
                    self.buf.append(d)
                    done()
                }
            }
        }
    }

    func close() {
        conn.send(content: Data([0x88, 0x00]), completion: .contentProcessed { _ in })
        conn.cancel()
    }

    private static func connClosed() -> NSError {
        NSError(domain: "WS", code: -3, userInfo: [NSLocalizedDescriptionKey: "连接已关闭"])
    }

    private enum WSError: Error {
        case closed
    }

    /// 解析一个完整的 WebSocket 帧；数据不足返回 nil；
    /// 收到关闭帧(0x8)抛错；收到 ping(0x9)忽略继续
    private static func unmask(_ buf: inout Data) throws -> Data? {
        guard buf.count >= 2 else { return nil }
        let op = buf[0] & 0x0F
        var plen = Int(buf[1] & 0x7F)
        var off = 2
        if plen == 126 {
            guard buf.count >= 4 else { return nil }
            plen = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt16.self) }.bigEndian)
            off += 2
        } else if plen == 127 {
            guard buf.count >= 10 else { return nil }
            var len: UInt64 = 0
            for i in 0..<8 { len = (len << 8) | UInt64(buf[off + i]) }
            plen = Int(len)
            off += 8
        }
        let masked = buf[1] & 0x80 != 0
        let restLen = off + (masked ? 4 : 0) + plen
        guard buf.count >= restLen else { return nil }

        if op == 0x8 {
            buf.removeSubrange(0..<restLen)
            throw WSError.closed
        }
        if op == 0x9 {
            buf.removeSubrange(0..<restLen)
            return nil
        }
        if !masked {
            defer { buf.removeSubrange(0..<restLen) }
            return buf.subdata(in: off..<off + plen)
        }
        let maskBytes = [buf[off], buf[off + 1], buf[off + 2], buf[off + 3]]
        off += 4
        var out = Data(count: plen)
        for i in 0..<plen { out[i] = buf[off + i] ^ maskBytes[i % 4] }
        buf.removeSubrange(0..<restLen)
        return out
    }
}
