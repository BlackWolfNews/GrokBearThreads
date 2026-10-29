import SwiftUI
import ThreadbearKit

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(QuickAskModel.self) private var quick
    /// In a quick ask's thread, the keyboard's been asked for in place of the big mic.
    @State private var typing = false
    let threadId: String
    @State private var detail: ThreadDetail?
    @State private var loaded = false
    @State private var draft = ""
    /// The last command sent from here, until the runner has taken it.
    @State private var sent: (id: String, status: CommandStatus?)?
    @State private var hibernateTarget: PhoneThread?
    @State private var markedSeen = false
    /// The oldest seq when "Load earlier" was tapped, until older messages
    /// arrive (the oldest seq changes) or the runner says it couldn't.
    /// (A backend before API 2.)
    @State private var loadingBefore: Int?
    /// From API 2: the newest `limit` messages and tool lines, from Convex.
    @State private var page: MessagePage?
    @State private var limit = ThreadView.firstPage
    static let firstPage = 80
    static let morePerPage = 200

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if loaded {
                ContentUnavailableView("This thread's gone", systemImage: "questionmark.folder",
                                       description: Text("It may have been deleted on the Mac."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(detail?.thread.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let thread = detail?.thread {
                // The Mac's header: the project's icon (or a folder) before the title.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        ProjectIconView(project: thread.projects?.first.flatMap { model.project($0.id) }, title: thread.projects?.first?.title, size: 20)
                        Text(thread.title.isEmpty ? "Untitled" : thread.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                menu(thread)
            }
        }
        .hibernateDialog(for: $hibernateTarget)
        .task(id: threadId) { await follow() }
        .task(id: "\(threadId):\(limit):\(model.hasMessagePages)") { await followMessages() }
        .task(id: sent?.id) { await followCommand() }
    }

    private func content(_ detail: ThreadDetail) -> some View {
        let thread = detail.thread
        // From API 2 the page from phone:messages (tool lines included);
        // until it arrives, and on an older backend, phone:thread's messages.
        let messages = page?.messages ?? detail.messages
        let items = ThreadItem.group(messages)
        let paged = model.hasMessagePages && page != nil
        let canLoadMore = paged ? page?.hasMore == true : thread.hasEarlier(than: detail.messages.first?.seq)
        // Paged: a bigger page has been asked for and hasn't arrived yet.
        let loadingMore = paged ? (page?.hasMore == true && messages.count < limit) : loadingBefore == detail.messages.first?.seq
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if canLoadMore {
                        EarlierButton(loading: loadingMore, fromMac: !paged) {
                            loadMore(thread, detail: detail, paged: paged)
                        }
                        // Scrolling up to it loads by itself, like any chat.
                        // Not on a short thread, where it's on screen at
                        // once and nobody asked.
                        .onAppear {
                            if messages.count >= 20 { loadMore(thread, detail: detail, paged: paged) }
                        }
                    }
                    ForEach(items) { item in
                        switch item {
                        case let .message(message): MessageView(message: message)
                        case let .tools(run): ToolRunView(items: run)
                        }
                    }
                    if let pending = thread.pendingApproval {
                        PendingCard(threadId: thread.threadId, pending: pending) { sent = ($0, nil) }
                    } else if thread.isBusy || thread.working != nil {
                        WorkingLine(text: thread.working)
                            .id("working:\(thread.status == .running)")
                    } else if thread.status == .error {
                        Label("The last turn failed. Send a message to try again.", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let note = sentNote {
                        Text(note).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.seq) { proxy.scrollTo("bottom", anchor: .bottom) }
            // A voice follow-up's reply is read out once the turn's over, so it's the answer and
            // not a line the agent wrote on the way.
            .onChange(of: "\(messages.last?.seq ?? 0):\(thread.isBusy)", initial: true) {
                guard !thread.isBusy, let reply = messages.last(where: { $0.role == .assistant }) else { return }
                quick.replyArrived(in: threadId, seq: reply.seq, text: reply.text)
            }
            .safeAreaInset(edge: .bottom) {
                if quick.voiceThreadId == threadId, !typing {
                    VoiceBar(threadId: threadId, afterSeq: messages.last?.seq ?? 0, working: thread.isBusy) { typing = true }
                } else {
                    Composer(text: $draft, placeholder: thread.isBusy ? "Steer the agent" : "Reply") { text in
                        await send(text, to: thread)
                    }
                }
            }
        }
    }

    /// "Waiting for the Mac" while a command sits in the queue, so a
    /// message sent with the lid shut doesn't look lost.
    private var sentNote: String? {
        guard let sent else { return nil }
        switch sent.status?.state {
        case .failed: return "Didn't go through: \(sent.status?.note ?? "the runner refused it")"
        case .done, .taken: return nil
        default: return model.offlineText != nil ? "Waiting for the Mac to wake up" : "Sending…"
        }
    }

    @ToolbarContentBuilder private func menu(_ thread: PhoneThread) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if thread.archivedAt != nil {
                    Button { change(.unarchive) } label: { Label("Back to the inbox", systemImage: "tray.and.arrow.up") }
                } else {
                    if thread.snoozedUntil != nil || thread.snoozedUntilRestart == true {
                        Button { change(.wake) } label: { Label("Wake", systemImage: "sun.max") }
                    } else {
                        Button { hibernateTarget = thread } label: { Label("Hibernate…", systemImage: "moon.zzz") }
                    }
                    Button { change(.archive) } label: { Label("Put in the Den", systemImage: "archivebox") }
                }
                Section {
                    Label(thread.cwd, systemImage: "folder")
                    Label([thread.accountId, thread.model].compactMap { $0 }.joined(separator: " · "), systemImage: "person.crop.circle")
                    if let cost = thread.costUsd, cost > 0 {
                        Label(String(format: "$%.2f so far", cost), systemImage: "dollarsign.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func follow() async {
        guard let backend = model.backend else { return }
        do {
            for try await value in backend.thread(threadId) {
                detail = value
                loaded = true
                if let thread = value?.thread, thread.unread || thread.needsYou, !InboxSections.needsAnswer(thread), !markedSeen {
                    // Opening it reads it, as on the Mac. Once per visit, so a
                    // reply arriving while it's open is read too but not spammed.
                    markedSeen = true
                    _ = try? await backend.update(threadId: threadId, change: .markSeen)
                } else if value?.thread.unread == false {
                    markedSeen = false
                }
            }
        } catch {
            model.report(error)
        }
    }

    /// API 2: the thread's newest `limit` messages, live from Convex.
    private func followMessages() async {
        guard model.hasMessagePages, let backend = model.backend else { return }
        do {
            for try await value in backend.messages(threadId, limit: limit) { page = value }
        } catch {
            model.report(error)
        }
    }

    /// Older messages: from API 2 a bigger page from Convex (works with the
    /// Mac asleep); before that, the runner pages them in.
    private func loadMore(_ thread: PhoneThread, detail: ThreadDetail, paged: Bool) {
        if paged {
            guard let page, page.hasMore, page.messages.count >= limit else { return }
            limit += ThreadView.morePerPage
        } else {
            loadEarlier(thread, before: detail.messages.first?.seq)
        }
    }

    private func followCommand() async {
        guard let id = sent?.id, let backend = model.backend else { return }
        do {
            for try await status in backend.command(id) {
                guard sent?.id == id else { return }
                sent?.status = status
                if status?.state == .done || status?.state == .taken { sent = nil; return }
            }
        } catch {}
    }

    private func send(_ text: String, to thread: PhoneThread) async -> Bool {
        guard let backend = model.backend else { return false }
        do {
            let id = try await backend.send(threadId: thread.threadId, text: text)
            sent = (id, nil)
            return true
        } catch {
            model.report(error)
            return false
        }
    }

    private func loadEarlier(_ thread: PhoneThread, before seq: Int?) {
        guard let seq, let backend = model.backend, loadingBefore != seq else { return }
        loadingBefore = seq
        Task {
            do {
                let id = try await backend.loadEarlier(threadId: thread.threadId, beforeSeq: seq)
                // The messages turn up in the thread's own query; this only
                // watches for a failure, or the Mac being asleep.
                for try await status in backend.command(id) {
                    if status?.state == .failed {
                        model.report(TransportError.server(status?.note ?? "The Mac couldn't send older messages."))
                        loadingBefore = nil
                        return
                    }
                    if status?.state == .done { break }
                }
            } catch {
                model.report(error)
            }
            // Done (or gone): if nothing older arrived, let it be tapped again.
            try? await Task.sleep(for: .seconds(2))
            if loadingBefore == seq { loadingBefore = nil }
        }
    }

    private func change(_ change: ThreadChange) {
        Task {
            guard let backend = model.backend else { return }
            do { _ = try await backend.update(threadId: threadId, change: change) } catch { model.report(error) }
        }
    }
}

/// The bottom of a quick ask's thread: a big mic for a follow-up out loud, in place of the text
/// box (which the keyboard button brings back). What you say goes to the agent when you stop, and
/// its answer is read out when its turn ends. Tap while it's talking to stop it.
private struct VoiceBar: View {
    @Environment(QuickAskModel.self) private var quick
    let threadId: String
    let afterSeq: Int
    let working: Bool
    var showKeyboard: () -> Void

    private var listening: Bool { quick.phase == .listening && quick.listeningFor == threadId }

    var body: some View {
        VStack(spacing: 10) {
            if listening {
                Text(quick.transcript.isEmpty ? "Listening" : quick.transcript)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(quick.transcript.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .animation(.easeOut(duration: 0.12), value: quick.transcript)
            } else if let note = note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button(action: showKeyboard) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Type instead")
                Spacer()
                Button(action: tap) {
                    ZStack {
                        if listening {
                            Circle().fill(Color.accentColor.opacity(0.14)).frame(width: 66, height: 66)
                                .scaleEffect(1.15 + quick.level * 0.6)
                        }
                        Circle().fill(Color.accentColor).frame(width: 66, height: 66)
                        Image(systemName: listening ? "waveform" : quick.isSpeaking ? "stop.fill" : "mic.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 110, height: 90)
                    .animation(.easeOut(duration: 0.12), value: quick.level)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(listening ? "Send" : quick.isSpeaking ? "Stop talking" : "Ask a follow-up")
                Spacer()
                // Balances the keyboard button, so the mic sits in the middle.
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
        .background(.bar)
    }

    /// Plain words for what's going on, when it isn't obvious from the thread.
    private var note: String? {
        if let problem = quick.followUpProblem { return "Didn't go through: \(problem)" }
        if case .idle(let notice?) = quick.phase { return notice }
        if quick.followUpSending { return "Sending…" }
        if quick.awaitingReply?.threadId == threadId, !working { return "Sent. The answer will be read out." }
        return nil
    }

    private func tap() {
        if listening {
            quick.micButton()
        } else if quick.isSpeaking {
            quick.stopSpeakingReply()
        } else {
            quick.listenForFollowUp(in: threadId, afterSeq: afterSeq)
        }
    }
}

/// At the top of a thread: older messages, from Convex (API 2) or from the
/// Mac on request (before).
struct EarlierButton: View {
    @Environment(AppModel.self) private var model
    var loading: Bool
    var fromMac = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(loading ? (fromMac && model.offlineText != nil ? "Waiting for the Mac to wake up" : "Loading…") : "Load earlier messages")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderless)
        .disabled(loading)
    }
}

struct MessageView: View {
    var message: PhoneMessage

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                userText
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(BubbleBackground().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                if let origin = originText {
                    Text(origin).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .assistant:
            MarkdownText(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolRunView(items: [message])
        }
    }

    /// An answer to a review reads as the Mac shows it: the review's icon
    /// and title small, then what he picked and his notes (Mike, 29 Oct).
    @ViewBuilder private var userText: some View {
        if let review = ReviewAnswer.parse(message.text) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(review.lines.enumerated()), id: \.offset) { i, line in
                    VStack(alignment: .leading, spacing: 2) {
                        // The same symbol as the Mac's review card and button.
                        (i == 0 ? Text("\(Image(systemName: "rectangle.on.rectangle")) \(line.label)") : Text(line.label))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(line.text)
                    }
                }
            }
        } else {
            Text(message.text)
        }
    }

    private var originText: String? {
        switch message.origin {
        case "phone": "From the phone"
        case "schedule": "Scheduled"
        case "runner": "From the runner"
        default: nil
        }
    }
}

/// Tool calls between two messages: up to three as small lines, more folded
/// into "12 tool calls" that opens to them. What they printed stays on the Mac.
struct ToolRunView: View {
    var items: [PhoneMessage]

    var body: some View {
        if items.count <= 3 {
            lines
        } else {
            DisclosureGroup {
                lines.padding(.top, 4)
            } label: {
                Text("\(items.count) tool calls")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .tint(.secondary)
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                Label {
                    Text(item.text).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: Self.symbol(item.toolKind)).imageScale(.small)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func symbol(_ kind: String?) -> String {
        switch kind {
        case "command": "terminal"
        case "read": "doc.text"
        case "edit", "write": "pencil"
        case "search": "magnifyingglass"
        case "web": "globe"
        case "task": "person.2"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Assistant text: block by block, so paragraphs, lists, headings and code
/// keep their shape; inline markdown inside each.
struct MarkdownText: View {
    let blocks: [Block]

    enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case bullet(String, marker: String)
        case code(String)
    }

    init(_ text: String) { blocks = Self.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(text): Text(Self.inline(text))
                case let .heading(text): Text(Self.inline(text)).font(.headline)
                case let .bullet(text, marker):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(Self.inline(text))
                    }
                case let .code(text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text).font(.system(.footnote, design: .monospaced)).padding(10)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code { blocks.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let match = line.firstMatch(of: /^#{1,6}\s+(.*)/) { flush(); blocks.append(.heading(String(match.1))); continue }
            if let match = line.firstMatch(of: /^[-*]\s+(.*)/) { flush(); blocks.append(.bullet(String(match.1), marker: "•")); continue }
            if let match = line.firstMatch(of: /^(\d+)[.)]\s+(.*)/) { flush(); blocks.append(.bullet(String(match.2), marker: "\(match.1).")); continue }
            paragraph.append(raw)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
