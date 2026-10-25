import Foundation

// MARK: - Qwen 实时（WebSocket）

/// Qwen-ASR-Realtime 会话。
/// 协议要点：session.update 关 VAD 走 manual 模式，音频以 base64 PCM16/16k 追加，
/// 结束时先 commit 再 finish；实时文本在 text+stash，最终文本在 transcript。
final class QwenRealtimeSession {
    private let apiKey: String
    private let url: URL
    private let language: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var recvTask: Task<Void, Never>?

    private let lock = NSLock()
    private var finalText: String?
    private var isFinished = false
    private var finalDelivered = false
    private var ready = false

    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    /// 建连期间先缓存音频，握手完成后再补发，避免开头几百毫秒被丢掉
    private var pending: [Data] = []

    init(apiKey: String, url: URL, language: String) {
        self.apiKey = apiKey
        self.url = url
        self.language = language
    }

    func start(onPartial: @escaping (String) -> Void,
               onFinal: @escaping (String) -> Void,
               onError: @escaping (String) -> Void) async throws {
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()

        var sessionCfg: [String: Any] = [
            "modalities": ["text"],
            "input_audio_format": "pcm",
            "sample_rate": 16000,
            "turn_detection": NSNull(),
        ]
        if !language.isEmpty {
            sessionCfg["input_audio_transcription"] = ["language": language]
        }
        try await send(["event_id": Self.eventID(), "type": "session.update", "session": sessionCfg])

        lock.lock()
        ready = true
        let buffered = pending
        pending.removeAll()
        lock.unlock()
        for chunk in buffered { await appendPCM(chunk) }

        recvTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func appendPCM(_ pcm: Data) async {
        guard !pcm.isEmpty else { return }
        lock.lock()
        let configured = ready
        if !configured { pending.append(pcm) }
        lock.unlock()
        guard configured else { return }
        try? await send([
            "event_id": Self.eventID(),
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString(),
        ])
    }

    func finish() async {
        // 释放得太快时，先把建连期间缓存的音频补发出去
        lock.lock()
        let buffered = pending
        pending.removeAll()
        let wasReady = ready
        ready = true
        lock.unlock()
        for chunk in buffered {
            try? await send([
                "event_id": Self.eventID(),
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString(),
            ])
        }

        try? await send(["event_id": Self.eventID(), "type": "input_audio_buffer.commit"])
        try? await send(["event_id": Self.eventID(), "type": "session.finish"])

        // 等最终结果或 session.finished；从未建连成功就不必等满 5 秒
        let deadline = Date().addingTimeInterval(wasReady ? 5 : 1)
        while Date() < deadline {
            lock.lock()
            let done = finalDelivered || isFinished
            lock.unlock()
            if done { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        lock.lock()
        let text = finalText
        let delivered = finalDelivered
        lock.unlock()
        if let text = text, !delivered {
            lock.lock(); finalDelivered = true; lock.unlock()
            onFinal?(text)
        }
        close()
    }

    func close() {
        recvTask?.cancel()
        recvTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func send(_ obj: [String: Any]) async throws {
        guard let task = task else {
            throw NSError(domain: "Qwen", code: -1, userInfo: [NSLocalizedDescriptionKey: "连接已关闭"])
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveLoop() async {
        guard let task = task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let raw): data = raw
                @unknown default: continue
                }
                handle(data)
            } catch {
                if !Task.isCancelled {
                    onError?("连接中断：\(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.text":
            // text 是已定稿前缀，stash 是还会被修正的草稿，拼起来才是完整预览
            let confirmed = obj["text"] as? String ?? ""
            let stash = obj["stash"] as? String ?? ""
            let preview = confirmed + stash
            if !preview.isEmpty { onPartial?(preview) }

        case "conversation.item.input_audio_transcription.completed":
            let transcript = (obj["transcript"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock()
            finalText = transcript
            let delivered = finalDelivered
            finalDelivered = true
            lock.unlock()
            if !delivered, !transcript.isEmpty { onFinal?(transcript) }

        case "session.finished":
            lock.lock()
            isFinished = true
            lock.unlock()

        case "error":
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
            onError?(message)

        default:
            break
        }
    }

    private static func eventID() -> String {
        "event_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 1000...9999))"
    }
}

// MARK: - Qwen 整段识别（同步 HTTP）

enum QwenFileASR {
    static func transcribe(wav: Data, apiKey: String, endpoint: URL,
                           model: String, language: String) async throws -> String {
        var asrOptions: [String: Any] = ["enable_itn": true]
        if !language.isEmpty { asrOptions["language"] = language }

        let body: [String: Any] = [
            "model": model,
            "input": [
                "messages": [[
                    "role": "user",
                    "content": [["audio": "data:audio/wav;base64," + wav.base64EncodedString()]],
                ]],
            ],
            "parameters": ["asr_options": asrOptions],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Qwen", code: -1, userInfo: [NSLocalizedDescriptionKey: "无 HTTP 响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Qwen", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: ASRUtil.httpError(http.statusCode, data)])
        }
        guard let obj = ASRUtil.jsonObject(from: data),
              let text = ASRUtil.firstString(forKeys: ["text"], in: obj) else {
            let preview = String(decoding: data.prefix(300), as: UTF8.self)
            throw NSError(domain: "Qwen", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "未解析出识别文本：\(preview)"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
