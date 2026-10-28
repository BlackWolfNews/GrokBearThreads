import SwiftUI
import ThreadbearCore

/// "Usage" in the activity bar, a panel in the dock: every login's limits,
/// grouped by pool and, within a pool, by provider (Mike, 28 Oct: pools are
/// what threads run on). A panel rather than a popover so it can stay open
/// beside a thread, or be dragged out into a window. The CLIs' versions are
/// in Updates. Everything comes from `accounts.updated` and
/// `pools.updated`; the times follow `app.now`, which ticks without asking
/// the runner anything.
struct UsagePanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let groups = UsageGroups.build(pools: app.poolsSupported ? app.pools : [], accounts: app.accounts)
        let notices = AccountUsageText.notices(app.accounts)
        ScrollView {
            VStack(alignment: .leading, spacing: zoomed(12)) {
                if !app.accounts.contains(where: { $0.usage != nil }) {
                    Text("The usage numbers need a newer runner.")
                        .font(.system(size: zoomed(12)))
                        .foregroundStyle(.secondary)
                }
                // Side by side when the addresses fit beside the bars;
                // in a narrow panel each address gets a line of its own
                // above its bars, rather than being cut to "mi...om".
                ViewThatFits(in: .horizontal) {
                    UsageTable(groups: groups, allAccounts: app.accounts, notices: notices.own, now: app.now)
                    UsageTable(groups: groups, allAccounts: app.accounts, notices: notices.own, now: app.now, stacked: true)
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
            }
            .padding(zoomed(16))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The logins as one small table: each pool's name and icon, then its
/// logins by provider, each provider with a header saying what its columns
/// are. A login's name, then what's left of the 5-hour and weekly windows,
/// with "left" said once in the header (a bare "54%" read as used as
/// easily as left). Under a login, only what's worth knowing: its note,
/// that it's at its limit or its numbers are old, when a short window
/// comes back, and the extras that decide something
/// (`AccountUsageText.extraLines`). One grid so every column lines up.
/// A login in two pools shows in both.
private struct UsageTable: View {
    let groups: [UsageGroups.Group]
    /// Every login, for a pool's fallback icon (its providers').
    let allAccounts: [Account]
    let notices: [String: String]
    let now: Date
    /// Each address on its own line over its bars, for a narrow panel.
    var stacked = false

    var body: some View {
        let hasFiveHour = groups.contains { $0.accounts.contains { AccountUsageText.mainWindows($0.usage).contains { $0.kind == "five_hour" } } }
        let columns = (stacked ? 0 : 1) + (hasFiveHour ? 2 : 1)
        // Pools get headings; groups that are just providers (an older
        // runner) don't, as the provider's own header names them.
        let pooled = groups.contains { $0.pool != nil }
        Grid(alignment: .leading, horizontalSpacing: zoomed(14), verticalSpacing: zoomed(6)) {
            ForEach(groups) { group in
            let firstGroup = group.id == groups.first?.id
            if pooled {
                GridRow {
                    Label {
                        Text(group.title)
                    } icon: {
                        Image(systemName: group.pool.map { Pools.symbol($0, accounts: allAccounts) } ?? "tray")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: zoomed(12.5), weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .gridCellColumns(columns)
                }
                .padding(.top, firstGroup ? 0 : zoomed(14))
            }
            ForEach(group.providers) { section in
            let first = !pooled && firstGroup && section.id == group.providers.first?.id
            // A pool of one provider doesn't name it: the pool's heading
            // says enough, and "Claude" under "Claude" read as noise.
            let named = !pooled || group.providers.count > 1
            if stacked && named {
                GridRow {
                    Text(ModelPicker.providerTitle(section.provider))
                        .accessibilityAddTraits(.isHeader)
                        .gridCellColumns(columns)
                }
                .font(.system(size: zoomed(11), weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, first ? 0 : zoomed(pooled ? 4 : 8))
            }
            GridRow {
                if !stacked {
                    Text(named ? ModelPicker.providerTitle(section.provider) : "")
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
            .padding(.top, (stacked && named) || first ? 0 : zoomed(pooled ? 4 : 8))
            ForEach(section.accounts) { account in
                let windows = AccountUsageText.mainWindows(account.usage)
                if stacked {
                    GridRow {
                        AccountNameCell(account: account, now: now).gridCellColumns(columns)
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
                        .gridCellColumns(columns)
                    }
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
