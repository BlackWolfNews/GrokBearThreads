import SwiftUI
import ThreadbareCore

/// "Usage" in the sidebar's footer: every account's limits, grouped by
/// provider, then the two CLIs' versions with what can be done about them.
/// Everything comes from `accounts.updated` and `clis.updated`; the times
/// follow `app.now`, which ticks without asking the runner anything.
struct UsagePopover: View {
    @Environment(AppModel.self) private var app

    static let width: CGFloat = 380

    var body: some View {
        let sections = UsageSections.build(app.accounts)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if sections.isEmpty || !sections.contains(where: { $0.accounts.contains { $0.usage != nil } }) {
                    Text("The usage numbers need a newer runner.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ForEach(sections, id: \.provider) { section in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(ModelPicker.providerTitle(section.provider))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.accounts) { account in
                            AccountUsageView(account: account, now: app.now)
                        }
                    }
                }
                if let source = AccountUsageText.sourceLine(app.accounts, now: app.now) {
                    Text(source)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Divider()
                CliSection()
            }
            .padding(16)
        }
        .frame(width: Self.width)
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
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

private struct AccountUsageView: View {
    let account: Account
    let now: Date

    var body: some View {
        let usage = account.usage
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(AccountName.title(account))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                // The plan, and Mike's note for the account, quietly after it.
                let about = [account.plan, account.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !about.isEmpty {
                    Text(about).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if usage?.blocked == true {
                    Text("Limit reached").font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                } else if usage?.stale == true, let readAt = usage?.readAt {
                    Text("From " + AccountUsageText.when(readAt, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("Token Stats hasn't updated this account since then")
                }
            }
            ForEach(AccountUsageText.mainWindows(usage), id: \.kind) { window in
                UsageBar(window: window, now: now)
            }
            ForEach(AccountUsageText.extraWindows(usage), id: \.title) { window in
                Text("\(window.title) \(AccountUsageText.windowLine(window, now: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let notice = usage?.notice, !notice.isEmpty {
                Text(notice).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if usage == nil {
                Text("Nothing known yet").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// One line per window: "5-hour", a thin bar of what's left, and "89%,
/// resets 3:40 pm".
private struct UsageBar: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(window.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(fill)
                        .frame(width: max(0, geometry.size.width * window.remainingPercent / 100))
                }
            }
            .frame(height: 4)
            Text(AccountUsageText.windowLine(window, now: now).replacingOccurrences(of: " left", with: ""))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 150, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title): \(AccountUsageText.windowLine(window, now: now))")
    }

    /// Grey while there's room; orange under a quarter; red when it's
    /// used up. Only the window that ran out is red, not the account's
    /// other one.
    private var fill: Color {
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
        VStack(alignment: .leading, spacing: 12) {
            if app.clisSupported == false || (app.clisSupported == nil && app.clis.isEmpty) {
                Text("The CLI versions need a newer runner.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.clis) { cli in
                    CliRow(cli: cli)
                }
                HStack {
                    if let checked = CliText.checkedLine(app.clis, now: app.now) {
                        Text(checked).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Check now") { app.checkClis() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
        }
    }
}

private struct CliRow: View {
    @Environment(AppModel.self) private var app
    let cli: CliStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(CliText.statusLine(cli))
                    .font(.system(size: 12))
                    .foregroundStyle(cli.status == "held" ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let title = CliText.updateTitle(cli) {
                    Button(title) { app.updateCli(cli.provider, force: cli.status == "held") }
                        .controlSize(.small)
                }
            }
            if let text = CliText.isUpdating(cli) ? CliText.bannerText(cli) : nil {
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let missing = cli.hold?.missing, !missing.isEmpty {
                Text("Missing: " + missing.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if let managed = CliText.managedLine(cli) {
                Text(managed).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Picker("Updates", selection: Binding(get: { cli.policy }, set: { app.setCliPolicy(cli.provider, $0) })) {
                    ForEach(CliText.policies, id: \.self) { Text(CliText.policyTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 200)
                .help("Whether new versions install by themselves")
                Spacer()
                if let back = CliText.goBackTitle(cli), let previous = cli.previousVersion {
                    Button(back) { app.updateCli(cli.provider, version: previous) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
        }
    }
}
