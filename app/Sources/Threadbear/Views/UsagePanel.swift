import SwiftUI
import ThreadbearCore

/// "Usage" in the sidebar's activity bar, a panel in the dock: every
/// account's limits, grouped by provider, then the two CLIs' versions with
/// what can be done about them. A panel rather than a popover (28 Oct) so
/// it can stay open beside a thread, or be dragged out into a window.
/// Everything comes from `accounts.updated` and `clis.updated`; the times
/// follow `app.now`, which ticks without asking the runner anything.
struct UsagePanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sections = UsageSections.build(app.accounts)
        let notices = AccountUsageText.notices(app.accounts)
        ScrollView {
            VStack(alignment: .leading, spacing: zoomed(12)) {
                if sections.isEmpty || !sections.contains(where: { $0.accounts.contains { $0.usage != nil } }) {
                    Text("The usage numbers need a newer runner.")
                        .font(.system(size: zoomed(12)))
                        .foregroundStyle(.secondary)
                }
                // Side by side when the addresses fit beside the bars;
                // in a narrow panel each address gets a line of its own
                // above its bars, rather than being cut to "mi...om".
                ViewThatFits(in: .horizontal) {
                    UsageTable(sections: sections, notices: notices.own, now: app.now)
                    UsageTable(sections: sections, notices: notices.own, now: app.now, stacked: true)
                }
                // Where the numbers came from, and what Token Stats says
                // about all of them, once.
                let source = [AccountUsageText.sourceLine(app.accounts, now: app.now), notices.shared].compactMap { $0 }
                if !source.isEmpty {
                    Text(source.joined(separator: ". "))
                        .font(.system(size: zoomed(11)))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().padding(.vertical, zoomed(4))
                CliSection()
            }
            .padding(zoomed(16))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Accounts by provider, Claude first, in the runner's order within each.
enum UsageSections {
    struct Section {
        var provider: String
        var accounts: [Account]
    }

    static func build(_ accounts: [Account]) -> [Section] {
        AccountMenu.sections(accounts, selected: "", now: Date()).map { section in
            Section(provider: section.id, accounts: section.items.compactMap { item in accounts.first { $0.id == item.id } })
        }
    }
}

/// One provider's accounts as a small table: the name, then what's left
/// of the 5-hour and weekly windows, with "left" said once in the header
/// (a bare "54%" read as used as easily as left). Under an account, only
/// what's worth knowing: its note, that it's at its limit or its numbers
/// are old, when a short window comes back, and the extras that decide
/// something (`AccountUsageText.extraLines`).
/// Claude and Codex share one grid so their columns line up.
private struct UsageTable: View {
    let sections: [UsageSections.Section]
    let notices: [String: String]
    let now: Date
    /// Each address on its own line over its bars, for a narrow panel.
    var stacked = false

    var body: some View {
        let hasFiveHour = sections.contains { $0.accounts.contains { AccountUsageText.mainWindows($0.usage).contains { $0.kind == "five_hour" } } }
        Grid(alignment: .leading, horizontalSpacing: zoomed(14), verticalSpacing: zoomed(6)) {
            ForEach(sections, id: \.provider) { section in
            if stacked {
                GridRow {
                    Text(ModelPicker.providerTitle(section.provider))
                        .accessibilityAddTraits(.isHeader)
                        .gridCellColumns(hasFiveHour ? 2 : 1)
                }
                .font(.system(size: zoomed(11), weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, section.provider == sections.first?.provider ? 0 : zoomed(8))
            }
            GridRow {
                if !stacked {
                    Text(ModelPicker.providerTitle(section.provider))
                        .accessibilityAddTraits(.isHeader)
                }
                // Codex's Pro Lite has only a week: its column stays, empty.
                if hasFiveHour {
                    Text(section.accounts.contains { AccountUsageText.mainWindows($0.usage).contains { $0.kind == "five_hour" } } ? "5-hour left" : "")
                }
                Text("Weekly left")
            }
            .font(.system(size: zoomed(11), weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.top, stacked || section.provider == sections.first?.provider ? 0 : zoomed(8))
            ForEach(section.accounts) { account in
                let windows = AccountUsageText.mainWindows(account.usage)
                if stacked {
                    GridRow {
                        AccountNameCell(account: account, now: now).gridCellColumns(hasFiveHour ? 2 : 1)
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    if !stacked { AccountNameCell(account: account, now: now) }
                    if hasFiveHour { RoomCell(window: windows.first { $0.kind == "five_hour" }, now: now) }
                    RoomCell(window: windows.first { $0.kind == "weekly" }, now: now)
                }
                let more = moreLines(account)
                if !more.isEmpty {
                    GridRow {
                        VStack(alignment: .leading, spacing: zoomed(2)) {
                            ForEach(more, id: \.text) { line in
                                Text(line.text)
                                    .foregroundStyle(line.loud ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.system(size: zoomed(11)))
                        .padding(.top, zoomed(-3))
                        .gridCellColumns((hasFiveHour ? 2 : 1) + (stacked ? 0 : 1))
                    }
                }
            }
            }
        }
    }

    private func moreLines(_ account: Account) -> [(text: String, loud: Bool)] {
        if account.usage == nil { return [("Nothing known yet", false)] }
        var lines: [(text: String, loud: Bool)] = []
        if let reset = AccountUsageText.resetLine(account.usage, now: now) { lines.append((reset, true)) }
        lines += AccountUsageText.extraLines(account.usage, notice: notices[account.id], now: now).map { ($0, false) }
        return lines
    }
}

/// The address, with the note ("Convex work only") or what's wrong under
/// it. The plan is in the tooltip: it never changed what Mike did.
private struct AccountNameCell: View {
    let account: Account
    let now: Date

    var body: some View {
        let usage = account.usage
        VStack(alignment: .leading, spacing: zoomed(1)) {
            Text(AccountName.title(account))
                .font(.system(size: zoomed(12.5), weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if usage?.blocked == true {
                Text("Limit reached").font(.system(size: zoomed(11), weight: .medium)).foregroundStyle(.red)
            } else if usage?.stale == true, let readAt = usage?.readAt {
                Text("Numbers from " + AccountUsageText.when(readAt, now: now))
                    .font(.system(size: zoomed(11)))
                    .foregroundStyle(.tertiary)
                    .tip("Token Stats hasn't updated this account since then")
            }
            if let note = account.note, !note.isEmpty {
                Text(note).font(.system(size: zoomed(11))).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .tip([AccountName.title(account), account.plan].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A thin bar of what's left and the percentage, the reset in its tooltip.
/// Grey while there's room; orange under a quarter; red when it's used up.
private struct RoomCell: View {
    let window: UsageWindow?
    let now: Date

    var body: some View {
        if let window {
            HStack(spacing: zoomed(6)) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(fill(window))
                        .frame(width: max(0, zoomed(44) * window.remainingPercent / 100))
                }
                .frame(width: zoomed(44), height: zoomed(4))
                Text(AccountUsageText.percent(window.remainingPercent))
                    .font(.system(size: zoomed(12)))
                    .monospacedDigit()
                    .foregroundStyle(window.remainingPercent < AccountUsageText.chipWarning ? AnyShapeStyle(fill(window)) : AnyShapeStyle(.secondary))
                    .frame(minWidth: zoomed(30), alignment: .trailing)
            }
            .tip("\(window.title): " + AccountUsageText.windowLine(window, now: now))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.title): \(AccountUsageText.windowLine(window, now: now))")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func fill(_ window: UsageWindow) -> Color {
        if window.remainingPercent < 1 { return .red }
        if window.remainingPercent < AccountUsageText.chipWarning { return .orange }
        return Color.primary.opacity(0.45)
    }
}

/// The two CLIs: their versions, Update (or Update anyway, or Go back),
/// whether updates install by themselves, and when the runner last looked.
private struct CliSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(12)) {
            if app.clisSupported == false || (app.clisSupported == nil && app.clis.isEmpty) {
                Text("The CLI versions need a newer runner.")
                    .font(.system(size: zoomed(12)))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.clis) { cli in
                    CliRow(cli: cli)
                }
                HStack {
                    if let checked = CliText.checkedLine(app.clis, now: app.now) {
                        Text(checked).font(.system(size: zoomed(11))).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Check now") { app.checkClis() }
                        .buttonStyle(.borderless)
                        .tip("Look for new versions of the CLIs now")
                        .font(.system(size: zoomed(11)))
                }
            }
        }
    }
}

private struct CliRow: View {
    @Environment(AppModel.self) private var app
    let cli: CliStatus

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(6)) {
            HStack(alignment: .firstTextBaseline) {
                Text(CliText.statusLine(cli))
                    .font(.system(size: zoomed(12)))
                    .foregroundStyle(cli.status == "held" ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: zoomed(6))
                if let title = CliText.updateTitle(cli) {
                    Button(title) { app.updateCli(cli.provider, force: cli.status == "held") }
                        .controlSize(.small)
                        .tip(cli.status == "held" ? "Install it even though the check held it back" : "Install the new version now")
                }
            }
            if let text = CliText.isUpdating(cli) ? CliText.bannerText(cli) : nil {
                Text(text).font(.system(size: zoomed(11))).foregroundStyle(.secondary)
            }
            if let missing = cli.hold?.missing, !missing.isEmpty {
                Text("Missing: " + missing.joined(separator: ", "))
                    .font(.system(size: zoomed(11)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if let managed = CliText.managedLine(cli) {
                Text(managed).font(.system(size: zoomed(11))).foregroundStyle(.tertiary)
            }
            HStack(spacing: zoomed(8)) {
                // A menu, not a segmented control: two rows of three
                // buttons were most of the popover's noise, and the choice
                // is set once and left.
                Menu {
                    ForEach(CliText.policies, id: \.self) { policy in
                        Button { app.setCliPolicy(cli.provider, policy) } label: {
                            if policy == cli.policy { Label(CliText.policyTitle(policy), systemImage: "checkmark") } else { Text(CliText.policyTitle(policy)) }
                        }
                    }
                } label: {
                    Text("Updates: " + CliText.policyTitle(cli.policy))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .controlSize(.small)
                .fixedSize()
                .foregroundStyle(.secondary)
                .tip("Whether new versions install by themselves")
                Spacer()
                if let back = CliText.goBackTitle(cli), let previous = cli.previousVersion {
                    Button(back) { app.updateCli(cli.provider, version: previous) }
                        .buttonStyle(.borderless)
                        .tip("Go back to the version you had before the last update")
                        .font(.system(size: zoomed(11)))
                }
            }
        }
    }
}
