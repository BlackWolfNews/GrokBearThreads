import SwiftUI
import ThreadbearKit

struct ThreadView: View {
    @Environment(AppModel.self) private var model
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
    @State private var loadingBefore: Int?

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
        .toolbar { if let thread = detail?.thread { menu(thread) } }
        .hibernateDialog(for: $hibernateTarget)
        .task(id: threadId) { await follow() }
        .task(id: sent?.id) { await followCommand() }
    }

    private func content(_ detail: ThreadDetail) -> some View {
        let thread = detail.thread
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if thread.hasEarlier(than: detail.messages.first?.seq) {
                        EarlierButton(loading: loadingBefore == detail.messages.first?.seq) {
                            loadEarlier(thread, before: detail.messages.first?.seq)
                        }
                        // Scrolling up to it loads by itself, like any chat.
                        // Not on a short thread, where it's on screen at
                        // once and nobody asked.
                        .onAppear {
                            if detail.messages.count >= 20 { loadEarlier(thread, before: detail.messages.first?.seq) }
                        }
                    }
                    ForEach(detail.messages) { MessageView(message: $0) }
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
            .onChange(of: detail.messages.last?.seq) { proxy.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) {
                Composer(text: $draft, placeholder: thread.isBusy ? "Steer the agent" : "Reply") { text in
                    await send(text, to: thread)
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

/// At the top of a thread: older messages come from the Mac on request.
struct EarlierButton: View {
    @Environment(AppModel.self) private var model
    var loading: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(loading ? (model.offlineText != nil ? "Waiting for the Mac to wake up" : "Loading…") : "Load earlier messages")
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
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
