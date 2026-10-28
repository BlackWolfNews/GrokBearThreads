import SwiftUI
import ThreadbearCore

/// The share icon beside the thread's ... menu: who else can read the
/// thread on the website (protocol "Sharing"). Only you, anyone with the
/// link, or specific people, who sign in with a code emailed to them. Out
/// of sight while threads aren't mirrored to Convex, as there's no website
/// to share on then.
struct ShareButton: View {
    @Environment(AppModel.self) private var app
    /// For a thread open in a panel of its own; nil for the main panel's.
    var pinned: String? = nil

    var body: some View {
        let thread = pinned.map { app.threads[$0] } ?? (pinned == nil && app.openProject == nil && !app.showsProjectsHome ? app.selectedThread : nil)
        let shown = thread != nil && app.websiteURL != nil
        let on = thread?.share?.isOn == true
        Button {
            guard let thread else { return }
            app.sharePopoverThread = app.sharePopoverThread == thread.id ? nil : thread.id
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: TypeScale.label, weight: .medium))
                // Accent only when it means something: someone else can read it.
                .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: zoomed(26), height: zoomed(26))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(thread.map(ShareText.buttonTip) ?? "Share")
        .popover(isPresented: Binding(
            get: { thread != nil && app.sharePopoverThread == thread?.id },
            set: { if !$0, app.sharePopoverThread == thread?.id { app.sharePopoverThread = nil } }
        ), arrowEdge: .bottom) {
            if let thread { SharePopover(threadId: thread.id) }
        }
        .disabled(!shown)
        .opacity(shown ? 1 : 0)
    }
}

/// What the share button and popover say, kept apart so tests can read it.
enum ShareText {
    static func buttonTip(_ thread: ThreadSummary) -> String {
        guard let share = thread.share else { return "Share this thread on the web" }
        switch share.access {
        case .off: return "Share this thread on the web"
        case .link: return "Shared: anyone with the link can read it"
        case .people:
            let n = share.people.count
            return n == 1 ? "Shared with \(share.people[0])" : "Shared with \(n) people"
        }
    }

    static func title(_ access: ThreadShare.Access) -> String {
        switch access {
        case .off: "Only you"
        case .link: "Anyone with the link"
        case .people: "Specific people"
        }
    }

    static func symbol(_ access: ThreadShare.Access) -> String {
        switch access {
        case .off: "lock"
        case .link: "globe"
        case .people: "person.2"
        }
    }

    static let about = "Whoever you share with reads this thread on your Threadbear website: its messages and one line per step, as it carries on. Tool output, images, its folder and cost stay on your Mac. Only you stops the link working; sharing again brings the same link back."

    /// The addresses typed into the field: split on commas, spaces and
    /// semicolons, lowercased, the ones that aren't addresses left out.
    static func emails(in text: String) -> (valid: [String], invalid: [String]) {
        var valid: [String] = []
        var invalid: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            let email = part.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased()
            if email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil { valid.append(email) } else { invalid.append(String(part)) }
        }
        return (valid, invalid)
    }
}

struct SharePopover: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    @State private var newPeople = ""
    @State private var busy = false
    @State private var copied = false
    @State private var problem: String?

    private var share: ThreadShare? { app.threads[threadId]?.share }
    private var access: ThreadShare.Access { share?.access ?? .off }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Share this thread").font(.headline)
                InfoTip(ShareText.about)
                Spacer()
            }

            Picker(selection: Binding(get: { access }, set: { change(to: $0) })) {
                ForEach(ThreadShare.Access.allCases, id: \.self) { a in
                    Label(ShareText.title(a), systemImage: ShareText.symbol(a)).tag(a)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(busy)
            .tip("Who can read it. Specific people sign in with a code emailed to them.")

            if access == .people { people }

            if let share, share.isOn, let link = app.shareLink(share) {
                HStack(spacing: 6) {
                    Text(link.absoluteString)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Task { await newLink() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .tip("Make a new link. The old one stops working, and anyone who signed in has to again.")
                    Button(copied ? "Copied" : "Copy link") { copy(link) }
                        .keyboardShortcut(.defaultAction)
                        .tip("Copy the link to paste anywhere")
                }
            }

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Add people by email", text: $newPeople)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await addPeople() } }
                    .tip("One or more email addresses. They get a code at that address to open the link.")
                Button("Add") { Task { await addPeople() } }
                    .disabled(busy || newPeople.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tip("Let these addresses read the thread")
            }
            ForEach(share?.people ?? [], id: \.self) { email in
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(email)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        Task { await remove(email) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .tip("Stop \(email) reading it. A browser they signed in with is shut out at once.")
                }
            }
        }
    }

    private func change(to next: ThreadShare.Access) {
        guard next != access else { return }
        Task { await run { try await app.share(threadId, access: next) } }
    }

    private func addPeople() async {
        let (valid, invalid) = ShareText.emails(in: newPeople)
        if !invalid.isEmpty {
            problem = invalid.count == 1 ? "\(invalid[0]) isn't an email address." : "These aren't email addresses: \(invalid.joined(separator: ", "))."
            return
        }
        guard !valid.isEmpty else { return }
        let list = (share?.people ?? []) + valid.filter { !(share?.people ?? []).contains($0) }
        await run { try await app.share(threadId, access: .people, people: list) }
        if problem == nil { newPeople = "" }
    }

    private func remove(_ email: String) async {
        await run { try await app.share(threadId, access: .people, people: (share?.people ?? []).filter { $0 != email }) }
    }

    private func newLink() async {
        await run { try await app.share(threadId, access: access, newLink: true) }
        copied = false
    }

    private func run(_ body: () async throws -> Void) async {
        busy = true
        problem = nil
        do { try await body() } catch { problem = error.localizedDescription }
        busy = false
    }

    private func copy(_ link: URL) {
        app.copyToPasteboard(link.absoluteString)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
