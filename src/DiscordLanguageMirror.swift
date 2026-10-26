import AppKit
import ApplicationServices
import SwiftUI
import Translation

@main
struct DiscordMirrorApp: App {
    var body: some Scene {
        WindowGroup("Discord 多语言镜像 0.5") {
            MirrorControls()
                .frame(minWidth: 350, minHeight: 230)
        }
        .windowResizability(.contentMinSize)
    }
}

private struct ChatMessage: Identifiable, Equatable {
    let id: String
    let author: String
    let time: String
    let original: String
    let bodyFrame: CGRect

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.bodyFrame == rhs.bodyFrame
    }
}

@MainActor
private final class MirrorModel: ObservableObject {
    @Published var running = false
    @Published var authorized = false
    @Published var status = "点击“开始”读取 Discord 聊天。"
    @Published var channel = ""
    @Published var messages: [ChatMessage] = []
    @Published var translations: [String: String] = [:]
    @Published var revision = 0
    @Published var translating = false
    @Published var overlayEnabled = true
    @Published var showComparison = false
    @Published var sourceCode = "en"
    @Published var targetCode = "zh-Hans"
    @Published var languageError = ""

    private var timer: Task<Void, Never>?
    private var pending: [String] = []
    private var queued = Set<String>()
    private var windowFrame = CGRect.zero
    private var overlay: NSPanel?

    func checkAuthorization() {
        authorized = AXIsProcessTrusted()
        if !authorized {
            status = "需要“辅助功能”权限，才能按发言者和消息位置读取 Discord。"
        }
    }

    func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        checkAuthorization()
    }

    func start() {
        checkAuthorization()
        guard authorized else { return }
        guard !running else { return }
        running = true
        status = "正在读取 Discord…"
        timer = Task { [weak self] in
            while let self, self.running, !Task.isCancelled {
                self.scan()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
        overlay?.orderOut(nil)
        status = "已暂停。"
    }

    func clearTranslations() {
        translations.removeAll()
        pending.removeAll()
        queued.removeAll()
        revision += 1
    }

    func translatePending(using session: TranslationSession) async {
        guard !translating else { return }
        translating = true
        defer {
            translating = false
            if running && !pending.isEmpty { revision += 1 }
        }
        while running && !pending.isEmpty && !Task.isCancelled {
            let text = pending.removeFirst()
            queued.remove(text)
            guard translations[text] == nil else { continue }
            do {
                let response = try await session.translate(text)
                translations[text] = polish(response.targetText)
            } catch {
                translations[text] = "翻译失败：\(error.localizedDescription)"
                languageError = "系统翻译遇到问题：\(error.localizedDescription)"
            }
        }
    }

    private func polish(_ text: String) -> String {
        guard sourceCode == "ja", targetCode == "zh-Hans" else { return text }
        return [
            ("噱头", "设定机制"),
            ("优先度", "优先级"),
            ("管制", "审核限制"),
            ("运Ａ", "运营人员"),
            ("运A", "运营人员"),
            ("Wazawaza", "特意")
        ].reduce(text) { result, term in
            result.replacingOccurrences(of: term.0, with: term.1)
        }
    }

    private func scan() {
        guard AXIsProcessTrusted() else {
            authorized = false
            stop()
            status = "辅助功能权限已关闭。"
            return
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hnc.Discord")
        guard !apps.isEmpty else {
            messages = []
            overlay?.orderOut(nil)
            status = "未找到 Discord 桌面客户端。"
            return
        }
        let candidates: [(window: AXUIElement, frame: CGRect, title: String, pid: pid_t)] = apps.flatMap { app in
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 1.0)
            return (AXReader.children(appElement, attribute: kAXWindowsAttribute as String) ?? []).compactMap { window -> (window: AXUIElement, frame: CGRect, title: String, pid: pid_t)? in
                guard let frame = AXReader.frame(window), frame.width > 400,
                      let title = AXReader.string(window, attribute: kAXTitleAttribute as String),
                      title.contains("Discord") else { return nil }
                return (window, frame, title, app.processIdentifier)
            }
        }
        guard let selected = candidates.max(by: { lhs, rhs in
            let l = (lhs.title.hasPrefix("#") ? 10_000_000.0 : 0) + lhs.frame.width * lhs.frame.height
            let r = (rhs.title.hasPrefix("#") ? 10_000_000.0 : 0) + rhs.frame.width * rhs.frame.height
            return l < r
        }) else {
            messages = []
            overlay?.orderOut(nil)
            status = "未找到 Discord 聊天窗口。"
            return
        }
        let window = selected.window
        let frame = selected.frame
        windowFrame = frame
        let title = selected.title
        let newChannel = title.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? title
        if channel != newChannel {
            channel = newChannel
            clearTranslations()
        }
        var found = [ChatMessage]()
        var seen = Set<String>()
        AXReader.walk(window, depth: 0, count: 0) { element in
            guard let message = AXReader.message(from: element, channel: newChannel),
                  message.bodyFrame.intersects(frame),
                  message.bodyFrame.height >= 10,
                  message.bodyFrame.minX > frame.minX + min(200, frame.width * 0.19),
                  message.bodyFrame.minY > frame.minY + 55,
                  message.bodyFrame.maxY < frame.maxY - 40,
                  seen.insert(message.id).inserted else { return false }
            found.append(message)
            return true
        }
        found.sort { $0.bodyFrame.minY < $1.bodyFrame.minY }
        if found != messages { messages = found }
        for message in found where translations[message.original] == nil && !queued.contains(message.original) {
            pending.append(message.original)
            queued.insert(message.original)
            revision += 1
        }
        status = found.isEmpty ? "当前窗口没有识别到可见消息。" : "\(newChannel) · 对应 \(found.count) 条可见消息"
        updateOverlay()
    }

    private func updateOverlay() {
        guard overlayEnabled, !messages.isEmpty,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              front == "com.hnc.Discord" || front == Bundle.main.bundleIdentifier else {
            overlay?.orderOut(nil)
            return
        }
        if overlay == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: MessageOverlay(model: self))
            overlay = panel
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        overlay?.setFrame(CGRect(x: windowFrame.minX, y: top - windowFrame.maxY,
                                 width: windowFrame.width, height: windowFrame.height), display: true)
        overlay?.orderFront(nil)
    }

    func refreshOverlay() { updateOverlay() }

    func relative(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - windowFrame.minX, y: rect.minY - windowFrame.minY,
               width: rect.width, height: rect.height)
    }
}

private enum AXReader {
    static func value(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    static func string(_ element: AXUIElement, attribute: String) -> String? {
        value(element, attribute: attribute) as? String
    }

    static func children(_ element: AXUIElement, attribute: String = kAXChildrenAttribute as String) -> [AXUIElement]? {
        value(element, attribute: attribute) as? [AXUIElement]
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let px = value(element, attribute: kAXPositionAttribute as String),
              let sx = value(element, attribute: kAXSizeAttribute as String),
              CFGetTypeID(px) == AXValueGetTypeID(), CFGetTypeID(sx) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(px as! AXValue, .cgPoint, &point),
              AXValueGetValue(sx as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func walk(_ element: AXUIElement, depth: Int, count: Int, onElement: (AXUIElement) -> Bool) {
        var remaining = 20000
        func visit(_ item: AXUIElement, _ level: Int) {
            guard remaining > 0, level < 50 else { return }
            remaining -= 1
            if onElement(item) { return }
            for child in children(item) ?? [] { visit(child, level + 1) }
        }
        visit(element, 0)
    }

    static func message(from element: AXUIElement, channel: String) -> ChatMessage? {
        guard let items = children(element), items.count >= 2,
              let headingIndex = items.firstIndex(where: { string($0, attribute: kAXRoleAttribute as String) == kAXHeadingRole as String }) else { return nil }
        let heading = items[headingIndex]
        let headingItems = descendants(of: heading, stopAtButtons: false)
        guard let author = headingItems.compactMap({ item -> String? in
            guard string(item, attribute: kAXRoleAttribute as String) == kAXButtonRole as String else { return nil }
            return string(item, attribute: kAXTitleAttribute as String) ?? string(item, attribute: kAXDescriptionAttribute as String)
        }).first, !author.isEmpty else { return nil }
        let time = headingItems.compactMap { string($0, attribute: kAXValueAttribute as String) }.first(where: { $0.contains("/") || $0.contains(":") }) ?? ""
        // Discord appends a message-action toolbar after the body. Reading every
        // sibling here would send labels such as “Reply” and “More” to Translation.
        guard headingIndex + 1 < items.count else { return nil }
        let bodies = descendants(of: items[headingIndex + 1], stopAtButtons: true)
            .filter { string($0, attribute: kAXRoleAttribute as String) == kAXStaticTextRole as String }
        let texts = bodies.compactMap { string($0, attribute: kAXValueAttribute as String) }.filter { !$0.isEmpty }
        let original = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty,
              let firstFrame = bodies.compactMap({ frame($0) }).first else { return nil }
        let bodyFrame = bodies.compactMap { frame($0) }.reduce(firstFrame) { $0.union($1) }
        let id = "\(channel)|\(author)|\(time)|\(original)"
        return ChatMessage(id: id, author: author, time: time, original: original, bodyFrame: bodyFrame)
    }

    static func descendants(of element: AXUIElement, stopAtButtons: Bool) -> [AXUIElement] {
        var result = [AXUIElement]()
        var remaining = 300
        func visit(_ item: AXUIElement, _ depth: Int) {
            guard remaining > 0, depth < 12 else { return }
            remaining -= 1
            result.append(item)
            let role = string(item, attribute: kAXRoleAttribute as String)
            if stopAtButtons && (role == kAXButtonRole as String || role == kAXHeadingRole as String) { return }
            for child in children(item) ?? [] { visit(child, depth + 1) }
        }
        visit(element, 0)
        return result
    }
}

private struct MessageOverlay: View {
    @ObservedObject var model: MirrorModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(model.messages) { message in
                    if let translated = model.translations[message.original], !translated.hasPrefix("翻译失败") {
                        let area = model.relative(message.bodyFrame)
                        let available = max(80, geometry.size.width - area.minX - 20)
                        let cardWidth = min(available, max(area.width, min(520, area.width + 200)))
                        Text(translated)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(max(1, Int(area.height / 16)))
                            .frame(width: cardWidth, height: max(16, area.height), alignment: .topLeading)
                            .background(Color(red: 0.17, green: 0.18, blue: 0.20).opacity(0.98))
                            .position(x: area.minX + cardWidth / 2, y: area.midY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MirrorControls: View {
    @StateObject private var model = MirrorModel()
    @State private var config: TranslationSession.Configuration?
    @State private var language = "auto"
    @State private var targetLanguage = "zh-Hans"

    private let languages = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"),
        ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("es", "西班牙语"), ("fr", "法语"), ("de", "德语"),
        ("ru", "俄语"), ("pt", "葡萄牙语"), ("it", "意大利语"),
        ("nl", "荷兰语"), ("ar", "阿拉伯语"), ("id", "印尼语"),
        ("th", "泰语"), ("vi", "越南语"), ("tr", "土耳其语")
    ]

    private var effectiveLanguage: String {
        if language != "auto" { return language }
        let name = model.channel.lowercased()
        if name.contains("日本") || name.contains("japan") { return "ja" }
        if name.contains("한국") || name.contains("korean") { return "ko" }
        if name.contains("fran") { return "fr" }
        if name.contains("deutsch") { return "de" }
        if name.contains("españ") { return "es" }
        if name.contains("рус") { return "ru" }
        if name.contains("bahasa") { return "id" }
        if name.contains("繁體") { return "zh-Hant" }
        if name.contains("简体") { return "zh-Hans" }
        return "en"
    }

    private func configure() {
        let source = effectiveLanguage
        let target = targetLanguage
        model.sourceCode = source
        model.targetCode = target
        model.languageError = ""
        config = nil
        guard source != target else {
            model.languageError = "原文和目标语言相同，请选另一种目标语言。"
            return
        }
        config = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target))
        Task {
            let availability = await LanguageAvailability().status(
                from: Locale.Language(identifier: source),
                to: Locale.Language(identifier: target))
            guard model.sourceCode == source, model.targetCode == target else { return }
            if availability == .unsupported {
                model.languageError = "这组语言目前不受此 Mac 的系统翻译支持，请换一种语言。"
                config = nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Discord 多语言镜像 0.5").font(.headline)
                Spacer()
                Button(model.running ? "暂停" : "开始") {
                    if model.running { model.stop(); config = nil }
                    else {
                        if language != "auto" || !model.channel.isEmpty { configure() }
                        model.start()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if !model.languageError.isEmpty {
                Text(model.languageError).font(.caption).foregroundStyle(.red)
            }
            if !model.authorized {
                Button("开启辅助功能权限") { model.requestAuthorization() }
            }
            HStack {
                Picker("原文语言", selection: $language) {
                    Text("跟随频道").tag("auto")
                    ForEach(languages, id: \.0) { item in Text(item.1).tag(item.0) }
                }
                Picker("译为", selection: $targetLanguage) {
                    ForEach(languages, id: \.0) { item in Text(item.1).tag(item.0) }
                }
            }
            .font(.caption)
            HStack {
                Toggle("覆盖原文", isOn: $model.overlayEnabled)
                Toggle("显示逐条对照", isOn: $model.showComparison)
            }
            .font(.caption)
            if model.showComparison {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(item.author)  \(item.time)").font(.caption.bold())
                                Text(item.original).font(.caption).foregroundStyle(.secondary)
                                Text(model.translations[item.original] ?? "翻译中…")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            } else {
                Spacer()
                Text("译文会盖在 Discord 对应消息的正文上；发言者、时间和回复仍留在原位。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .translationTask(config) { session in await model.translatePending(using: session) }
        .onChange(of: model.revision) {
            if model.running && !model.translating { config?.invalidate() }
        }
        .onChange(of: model.channel) {
            if language == "auto" && model.running && (config == nil || model.sourceCode != effectiveLanguage) {
                model.clearTranslations()
                configure()
            }
        }
        .onChange(of: language) {
            model.clearTranslations()
            if model.running { configure() }
        }
        .onChange(of: targetLanguage) {
            model.clearTranslations()
            if model.running { configure() }
        }
        .onChange(of: model.overlayEnabled) { model.refreshOverlay() }
        .onAppear {
            model.checkAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let window = NSApp.windows.first(where: { $0.title.contains("Discord 多语言镜像") }) {
                    window.setContentSize(NSSize(width: 450, height: 270))
                    window.level = .floating
                }
            }
        }
    }
}
