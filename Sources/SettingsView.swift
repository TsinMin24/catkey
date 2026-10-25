import SwiftUI
import AppKit

// MARK: - 设计令牌
//
// 瑞士国际主义（International Typographic Style）：
// 网格、非对称两栏、大量留白、发丝线分隔、无圆角无阴影，
// 只用黑 / 纸白 / 一个信号红。
//
// 字体规则：中文用系统里的方正 FW 马蒂斯体（有 Thin→Heavy 六档），
// 拉丁字母和数字用系统无衬线（Helvetica Neue 系）。马蒂斯的拉丁是衬线字形，
// 放在 10–12pt 的标签和数字上会糊，也会破坏瑞士式的中性感，所以按字符分开排。
// 唯一保留马蒂斯拉丁的是左上角的字标 "Magic Key"——那是品牌出现的位置。

struct MKPalette {
    let paper: Color
    let ink: Color
    let muted: Color
    let rule: Color
    let accent: Color
    let inverse: Color

    static let light = MKPalette(
        paper: Color(red: 0.980, green: 0.980, blue: 0.973),
        ink: Color(red: 0.067, green: 0.067, blue: 0.067),
        muted: Color(red: 0.463, green: 0.463, blue: 0.447),
        rule: Color(red: 0.863, green: 0.863, blue: 0.839),
        accent: Color(red: 0.824, green: 0.180, blue: 0.118),
        inverse: Color.white
    )

    static let dark = MKPalette(
        paper: Color(red: 0.063, green: 0.063, blue: 0.063),
        ink: Color(red: 0.949, green: 0.949, blue: 0.933),
        muted: Color(red: 0.541, green: 0.541, blue: 0.522),
        rule: Color(red: 0.173, green: 0.173, blue: 0.165),
        accent: Color(red: 0.910, green: 0.267, blue: 0.184),
        inverse: Color(red: 0.063, green: 0.063, blue: 0.063)
    )

    static func of(_ scheme: ColorScheme) -> MKPalette {
        scheme == .dark ? .dark : .light
    }
}

private struct MKPaletteKey: EnvironmentKey {
    static let defaultValue = MKPalette.light
}

extension EnvironmentValues {
    var mk: MKPalette {
        get { self[MKPaletteKey.self] }
        set { self[MKPaletteKey.self] = newValue }
    }
}

enum MKWeight {
    case thin, light, regular, medium, bold, heavy

    var postScriptName: String {
        switch self {
        case .thin: return "FZFWMADSTS-T--GB1-0"
        case .light: return "FZFWMADSTS-L--GB1-0"
        case .regular: return "FZFWMADSTS-R--GB1-0"
        case .medium: return "FZFWMADSTS-M--GB1-0"
        case .bold: return "FZFWMADSTS-B--GB1-0"
        case .heavy: return "FZFWMADSTS-H--GB1-0"
        }
    }
}

extension Font {
    static func matisse(_ size: CGFloat, _ weight: MKWeight = .regular) -> Font {
        .custom(weight.postScriptName, size: size)
    }
}

/// 全页统一马蒂斯：中文、拉丁字母、数字都用同一套字形
func mkText(_ string: String, size: CGFloat, weight: MKWeight = .regular) -> Text {
    Text(string).font(.matisse(size, weight))
}

// MARK: - 基础元件

struct MKRule: View {
    @Environment(\.mk) private var mk
    var body: some View {
        Rectangle()
            .fill(mk.rule)
            .frame(height: 0.5)
    }
}

/// 左标签 + 右内容的固定网格行
struct MKRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 84
    @ViewBuilder var content: Content

    @Environment(\.mk) private var mk

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            mkText(label, size: 11, weight: .light)
                .foregroundColor(mk.muted)
                .frame(width: labelWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
    }
}

/// 分段选择：横向分格，选中项用信号红上边线 + 实心字
struct MKChoice<Option: Hashable>: View {
    let options: [(value: Option, title: String)]
    @Binding var selection: Option

    @Environment(\.mk) private var mk

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    selection = option.value
                } label: {
                    mkText(option.title, size: 11, weight: selection == option.value ? .medium : .light)
                        .foregroundColor(selection == option.value ? mk.ink : mk.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(selection == option.value ? mk.accent : mk.rule)
                                .frame(height: 1)
                        }
                        .overlay(alignment: .leading) {
                            if index > 0 {
                                Rectangle().fill(mk.rule).frame(width: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 下划线输入框
struct MKField: View {
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false
    var trailing: AnyView? = nil

    @Environment(\.mk) private var mk
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Group {
                    if secure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.matisse(11))
                .foregroundColor(mk.ink)
                .focused($focused)

                if let trailing {
                    trailing
                }
            }
            Rectangle()
                .fill(focused ? mk.accent : mk.rule)
                .frame(height: 0.5)
        }
    }
}

/// 预设下拉（选项少、改动少，用菜单而不是分段）
struct MKMenu<Option: Hashable>: View {
    let title: String
    let options: [(value: Option, title: String)]
    @Binding var selection: Option

    @Environment(\.mk) private var mk

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.title) { selection = option.value }
            }
        } label: {
            HStack(spacing: 6) {
                mkText(title, size: 12)
                    .foregroundColor(mk.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .regular))
                    .foregroundColor(mk.muted)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 键帽：这一页唯一的“图形”，因为 F13/F20 本来就是实体按键
struct MKKeycap: View {
    let key: String
    var active: Bool = false

    @Environment(\.mk) private var mk

    var body: some View {
        Text(key)
            .font(.matisse(9.5))
            .foregroundColor(active ? mk.inverse : mk.ink)
            .frame(width: 34, height: 24)
            .background(active ? mk.ink : Color.clear)
            .overlay(Rectangle().stroke(mk.rule, lineWidth: 0.5))
    }
}

/// 比键帽更宽的可变宽按键徽标，用于显示 ⌥Space 这类组合键
struct MKKeyBadge: View {
    let text: String
    var active: Bool = false

    @Environment(\.mk) private var mk

    var body: some View {
        mkText(text, size: 11)
            .foregroundColor(active ? mk.accent : mk.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(Rectangle().stroke(active ? mk.accent : mk.rule, lineWidth: 0.5))
    }
}

/// 区块标题：标题 + 右侧元信息 + 发丝线
struct MKSectionHeader: View {
    let title: String
    var meta: String = ""

    @Environment(\.mk) private var mk

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                mkText(title, size: 13, weight: .medium)
                    .foregroundColor(mk.ink)
                Spacer()
                mkText(meta, size: 10, weight: .light)
                    .foregroundColor(mk.muted)
            }
            MKRule()
        }
        .padding(.top, 26)
        .padding(.bottom, 4)
    }
}

// MARK: - 设置页

struct SettingsView: View {
    @ObservedObject private var store = KeyBindingStore.shared
    @ObservedObject private var recorder = RecordingObserver.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var provider: ASRProvider = ASRSettings.provider
    @State private var mode: ASRMode = ASRSettings.mode
    @State private var language: String = ASRSettings.language
    @State private var volcKey: String = UserDefaults.standard.string(forKey: "VolcengineAPIKey") ?? ""
    @State private var qwenKey: String = ASRSettings.qwenAPIKey
    @State private var qwenPreset: QwenPreset = SettingsView.detectQwenPreset()
    @State private var qwenRealtime: String = ASRSettings.qwenRealtimeURL
    @State private var qwenHTTP: String = ASRSettings.qwenHTTPURL
    @State private var qwenModel: String = ASRSettings.qwenModel
    @State private var mimoKey: String = ASRSettings.mimoAPIKey
    @State private var mimoPreset: MiMoPreset = SettingsView.detectMiMoPreset()
    @State private var mimoAuth: MiMoAuth = ASRSettings.mimoAuth
    @State private var mimoURL: String = ASRSettings.mimoURL
    @State private var mimoModel: String = ASRSettings.mimoModel
    @State private var showAPIKey = false
    @State private var savedText = ""
    @State private var pttLabel: String = PTTSettings.label
    @State private var pttKeyCode: Int = PTTSettings.keyCode
    @State private var pttModifiers: UInt = PTTSettings.modifiers
    @State private var pttMode: PTTMode = PTTSettings.mode
    @State private var capturingKey = false
    @State private var keyMonitor: Any?

    private var mk: MKPalette { MKPalette.of(colorScheme) }

    // MARK: 派生状态

    private var apiKeyBinding: Binding<String> {
        switch provider {
        case .volcengine: return $volcKey
        case .qwen: return $qwenKey
        case .mimo: return $mimoKey
        }
    }

    private var apiKeyPlaceholder: String {
        switch provider {
        case .volcengine: return "粘贴火山引擎 API Key"
        case .qwen: return "粘贴 DashScope API Key（sk-…）"
        case .mimo: return "粘贴 MiMo API Key（sk- / tp-）"
        }
    }

    private var hintText: String {
        switch provider {
        case .volcengine:
            return "新版鉴权只要一个 API Key，不需要 App ID / Access Key / Secret Key。"
        case .qwen:
            return "预设会同时改实时与整段两条地址；Key 和站点必须对应，国内站与国际站不通用。"
        case .mimo:
            return mode == .streaming
                ? "MiMo 不支持边录边传：流式指整段上传后边返回边出字。Token Plan 的 Key（tp- / ttp-）要选对应预设。"
                : "MiMo 整段上传 WAV，base64 后上限约 10 MB。"
        }
    }

    private var providerShort: String {
        switch provider {
        case .volcengine: return "火山"
        case .qwen: return "Qwen"
        case .mimo: return "MiMo"
        }
    }

    static func detectQwenPreset() -> QwenPreset {
        let realtime = ASRSettings.qwenRealtimeURL
        let http = ASRSettings.qwenHTTPURL
        for preset in [QwenPreset.cn, .intl]
        where preset.realtimeURL == realtime && preset.httpURL == http {
            return preset
        }
        return .custom
    }

    static func detectMiMoPreset() -> MiMoPreset {
        let url = ASRSettings.mimoURL
        for preset in [MiMoPreset.payAsYouGo, .tokenPlanCN, .tokenPlanSGP, .tokenPlanAMS]
        where preset.url == url { return preset }
        return .custom
    }

    // MARK: 录音键捕获

    private var pttConflictWarning: String? {
        guard let bound = store.bindings.first(where: { $0.key == pttLabel }),
              !bound.appBundleID.isEmpty else { return nil }
        return "\(pttLabel) 目前绑定了 \(bound.appName)，保存后该键优先用于录音，应用切换会失效。"
    }

    private func startKeyCapture() {
        guard keyMonitor == nil else { return }
        capturingKey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Esc 取消
                stopKeyCapture()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            pttKeyCode = Int(event.keyCode)
            pttModifiers = flags.rawValue
            pttLabel = KeyNamer.label(keyCode: Int(event.keyCode),
                                      characters: event.charactersIgnoringModifiers,
                                      flags: flags)
            stopKeyCapture()
            return nil
        }
    }

    private func stopKeyCapture() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        capturingKey = false
    }

    // MARK: 保存

    private func saveASRConfig() {
        ASRSettings.provider = provider
        ASRSettings.mode = mode
        ASRSettings.language = language
        UserDefaults.standard.set(volcKey, forKey: "VolcengineAPIKey")
        ASRSettings.qwenAPIKey = qwenKey
        ASRSettings.qwenPreset = qwenPreset
        if !qwenRealtime.isEmpty { ASRSettings.qwenRealtimeURL = qwenRealtime }
        if !qwenHTTP.isEmpty { ASRSettings.qwenHTTPURL = qwenHTTP }
        if !qwenModel.isEmpty { ASRSettings.qwenModel = qwenModel }
        ASRSettings.mimoAPIKey = mimoKey
        ASRSettings.mimoPreset = mimoPreset
        ASRSettings.mimoAuth = mimoAuth
        if !mimoURL.isEmpty { ASRSettings.mimoURL = mimoURL }
        if !mimoModel.isEmpty { ASRSettings.mimoModel = mimoModel }

        PTTSettings.keyCode = pttKeyCode
        PTTSettings.modifiers = pttModifiers
        PTTSettings.label = pttLabel
        PTTSettings.mode = pttMode
        PushToTalkManager.shared.reload()
        HotkeyManager.shared.registerAll()

        savedText = "设置已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if savedText == "设置已保存" { savedText = "" }
        }
    }

    // MARK: 布局

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    bindingSection
                    voiceSection
                    footer
                }
                // 固定内容宽度（520 − 左右 32），否则长 URL 会把内容撑宽后被直接裁掉
                .frame(width: 456, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 24)
            }

            actionBar
            MKLogPanel()
        }
        .frame(width: 520, height: 800)
        .background(mk.paper)
        .environment(\.mk, mk)
        .onDisappear { stopKeyCapture() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                mkText("Magic Key", size: 27, weight: .medium)
                    .tracking(-0.3)
                    .foregroundColor(mk.ink)
                mkText("键盘与语音输入", size: 11, weight: .light)
                    .foregroundColor(mk.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                mkText("\(providerShort) · \(mode == .streaming ? "流式" : "非流式")",
                       size: 10, weight: .light)
                    .foregroundColor(mk.muted)
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(recorder.isRecording ? mk.accent : mk.rule)
                        .frame(width: 5, height: 5)
                    mkText(recorder.isRecording ? "录音中" : "待命", size: 10, weight: .light)
                        .foregroundColor(recorder.isRecording ? mk.accent : mk.muted)
                }
            }
            .padding(.top, 5)
        }
        .padding(.bottom, 2)
    }

    private var bindingSection: some View {
        VStack(spacing: 0) {
            MKSectionHeader(title: "按键绑定", meta: "F5 / F13–F24")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], spacing: 0) {
                ForEach(Array(store.bindings.enumerated()), id: \.offset) { index, binding in
                    BindingCell(binding: binding) { updated in
                        store.bindings[index] = updated
                        HotkeyManager.shared.registerAll()
                    }
                }
            }
            MKRule()
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MKSectionHeader(title: "语音输入",
                            meta: pttMode == .hold ? "按住 \(pttLabel) 说话" : "按一下 \(pttLabel) 开始/停止")

            MKRow(label: "录音按键") {
                HStack(spacing: 12) {
                    MKKeyBadge(text: capturingKey ? "请按键…" : pttLabel, active: capturingKey)
                    Button(capturingKey ? "取消" : "重新设定") {
                        if capturingKey { stopKeyCapture() } else { startKeyCapture() }
                    }
                    .buttonStyle(.plain)
                    .font(.matisse(10, .light))
                    .foregroundColor(capturingKey ? mk.accent : mk.muted)
                }
            }
            MKRule()

            if capturingKey {
                mkText("可以直接按单个键（F13–F20、字母、空格等），也可以按住 ⌃⌥⇧⌘ 再按任意键组成组合键；Esc 取消。",
                       size: 10, weight: .light)
                    .foregroundColor(mk.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }

            MKRow(label: "触发方式") {
                MKChoice(options: PTTMode.allCases.map { (value: $0, title: $0.displayName) },
                         selection: $pttMode)
            }
            MKRule()

            if let warning = pttConflictWarning {
                mkText(warning, size: 10, weight: .light)
                    .foregroundColor(mk.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }

            MKRow(label: "供应商") {
                MKChoice(options: ASRProvider.allCases.map { (value: $0, title: shortName($0)) },
                         selection: $provider)
            }
            MKRule()

            MKRow(label: "模式") {
                MKChoice(options: ASRMode.allCases.map {
                            (value: $0, title: $0 == .streaming ? "流式" : "非流式")
                         },
                         selection: $mode)
            }
            MKRule()

            MKRow(label: "API Key") {
                MKField(placeholder: apiKeyPlaceholder,
                        text: apiKeyBinding,
                        secure: !showAPIKey,
                        trailing: AnyView(
                            Button(showAPIKey ? "隐藏" : "显示") { showAPIKey.toggle() }
                                .buttonStyle(.plain)
                                .font(.matisse(10, .light))
                                .foregroundColor(mk.muted)
                        ))
            }
            MKRule()

            if provider == .qwen {
                MKRow(label: "预设") {
                    MKMenu(title: qwenPreset.displayName,
                           options: QwenPreset.allCases.map { (value: $0, title: $0.displayName) },
                           selection: $qwenPreset)
                        .onChange(of: qwenPreset) { newValue in
                            guard newValue != .custom else { return }
                            qwenRealtime = newValue.realtimeURL
                            qwenHTTP = newValue.httpURL
                        }
                }
                MKRule()

                MKRow(label: "实时地址") {
                    endpointValue(qwenRealtime, editable: qwenPreset == .custom, binding: $qwenRealtime)
                }
                MKRule()

                MKRow(label: "整段地址") {
                    endpointValue(qwenHTTP, editable: qwenPreset == .custom, binding: $qwenHTTP)
                }
                MKRule()

                MKRow(label: "模型") {
                    MKField(placeholder: "qwen3-asr-flash", text: $qwenModel)
                }
                MKRule()
            }

            if provider == .mimo {
                MKRow(label: "预设") {
                    MKMenu(title: mimoPreset.displayName,
                           options: MiMoPreset.allCases.map { (value: $0, title: $0.displayName) },
                           selection: $mimoPreset)
                        .onChange(of: mimoPreset) { newValue in
                            guard newValue != .custom else { return }
                            mimoURL = newValue.url
                        }
                }
                MKRule()

                MKRow(label: "接口地址") {
                    endpointValue(mimoURL, editable: mimoPreset == .custom, binding: $mimoURL)
                }
                MKRule()

                MKRow(label: "模型") {
                    MKField(placeholder: "mimo-v2.5-asr", text: $mimoModel)
                }
                MKRule()

                MKRow(label: "鉴权") {
                    MKChoice(options: MiMoAuth.allCases.map {
                                (value: $0, title: $0 == .apiKey ? "api-key 头" : "Bearer")
                             },
                             selection: $mimoAuth)
                }
                MKRule()
            }

            MKRow(label: "语言") {
                MKChoice(options: [(value: "", title: "自动"),
                                   (value: "zh", title: "中文"),
                                   (value: "en", title: "English")],
                         selection: $language)
            }
            MKRule()

            mkText(hintText, size: 10, weight: .light)
                .foregroundColor(mk.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MKSectionHeader(title: "系统权限")

            HStack(spacing: 24) {
                permissionLink("辅助功能", "Privacy_Accessibility")
                permissionLink("输入监控", "Privacy_ListenEvent")
                permissionLink("麦克风", "Privacy_Microphone")
            }
            .padding(.top, 4)

            mkText("三项缺一不可：没有辅助功能无法注入文字，没有输入监控收不到 \(pttLabel)，没有麦克风录不到声音。",
                   size: 10, weight: .light)
                .foregroundColor(mk.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    /// 常驻底部操作条：内容再长，保存按钮也不会被滚走
    private var actionBar: some View {
        VStack(spacing: 0) {
            MKRule()
            HStack(spacing: 14) {
                Button(action: saveASRConfig) {
                    mkText("保存设置", size: 12, weight: .medium)
                        .foregroundColor(mk.inverse)
                        .frame(width: 116, height: 34)
                        .background(mk.ink)
                }
                .buttonStyle(.plain)

                mkText(savedText, size: 10, weight: .light)
                    .foregroundColor(mk.accent)

                Spacer()

                mkText(recorder.isRecording
                       ? "停止中…"
                       : (pttMode == .hold ? "\(pttLabel) 按住说话" : "\(pttLabel) 按一下切换"),
                       size: 10, weight: .light)
                    .foregroundColor(mk.muted)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
        }
        .background(mk.paper)
    }

    private func permissionLink(_ title: String, _ pane: String) -> some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            mkText(title, size: 11)
                .foregroundColor(mk.ink)
                .underline(true, color: mk.rule)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func shortName(_ provider: ASRProvider) -> String {
        switch provider {
        case .volcengine: return "火山"
        case .qwen: return "Qwen"
        case .mimo: return "MiMo"
        }
    }

    @ViewBuilder
    private func endpointValue(_ value: String, editable: Bool, binding: Binding<String>) -> some View {
        if editable {
            MKField(placeholder: "https://…", text: binding)
        } else {
            // 地址太长，拆成「协议+域名」「路径」两行，比中间省略号好读
            let (host, rest) = splitEndpoint(value)
            VStack(alignment: .leading, spacing: 2) {
                Text(host)
                    .font(.matisse(10))
                    .foregroundColor(mk.ink.opacity(0.72))
                    .lineLimit(1)
                if !rest.isEmpty {
                    Text(rest)
                        .font(.matisse(9.5))
                        .foregroundColor(mk.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func splitEndpoint(_ value: String) -> (String, String) {
        guard let scheme = value.range(of: "://") else { return (value, "") }
        let afterScheme = scheme.upperBound
        if let slash = value[afterScheme...].firstIndex(of: "/") {
            return (String(value[..<slash]), String(value[slash...]))
        }
        return (value, "")
    }
}

// MARK: - 绑定单元

private struct BindingCell: View {
    let binding: KeyBinding
    let onUpdate: (KeyBinding) -> Void

    @Environment(\.mk) private var mk
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            MKKeycap(key: binding.key)

            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
            }

            mkText(binding.appName.isEmpty ? "未绑定" : binding.appName,
                   size: 11,
                   weight: binding.appName.isEmpty ? .light : .regular)
                .foregroundColor(binding.appName.isEmpty ? mk.muted : mk.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // 「选择/更换」+「清除」始终占同样宽度，
            // 否则绑定后多出一个按钮会把前一个往左挤，两列对不齐
            HStack(spacing: 10) {
                Button(binding.appName.isEmpty ? "选择" : "更换") {
                    selectApp()
                }
                .buttonStyle(.plain)
                .font(.matisse(10, .light))
                .foregroundColor(hovering ? mk.ink : mk.muted)

                Button {
                    onUpdate(KeyBinding(key: binding.key, appName: "", appBundleID: ""))
                } label: {
                    mkText("清除", size: 10, weight: .light)
                        .foregroundColor(mk.muted)
                }
                .buttonStyle(.plain)
                .opacity(binding.appName.isEmpty ? 0 : (hovering ? 1 : 0))
                .disabled(binding.appName.isEmpty)
            }
            .frame(width: 64, alignment: .trailing)
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) { MKRule() }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var appIcon: NSImage? {
        guard !binding.appBundleID.isEmpty,
              let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.appBundleID)?.path
        else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    private func selectApp() {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            let bundle = Bundle(url: url)
            let appName = url.deletingPathExtension().lastPathComponent
            let bundleID = bundle?.bundleIdentifier ?? ""
            onUpdate(KeyBinding(key: binding.key, appName: appName, appBundleID: bundleID))
        }
    }
}
