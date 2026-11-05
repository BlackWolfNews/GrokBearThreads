import Foundation

/// What the Runners panel and its activity bar icon say about each runner
/// (`runners.list`, docs/protocol.md). Mike asked on 5 Nov for the website's
/// runner view on the Mac: which machines are up, what they're on and what
/// they're running, without going to Settings.
public enum RunnersText {
    public enum State: Equatable, Sendable {
        case online
        /// An old release finishing its threads in a handover.
        case updating
        case offline
    }

    public static func state(_ r: RunnerInfo) -> State {
        guard r.online else { return .offline }
        return r.draining ? .updating : .online
    }

    /// The line under a runner's name: "Online, up 3h", "Updating",
    /// "Offline, last seen 2d ago".
    public static func stateLine(_ r: RunnerInfo, now: Date) -> String {
        switch state(r) {
        case .online:
            return r.startedAt.map { "Online, up \(span(from: $0, to: now))" } ?? "Online"
        case .updating:
            return "Updating"
        case .offline:
            return r.lastSeenAt.map { "Offline, last seen \(span(from: $0, to: now)) ago" } ?? "Offline"
        }
    }

    /// The short commit of the release it runs ("c4d90ca" from
    /// "20261105T064853Z-c4d90ca"), or its version for one running from a
    /// checkout ("0.1.0+source"). Nil from a runner that doesn't say.
    public static func build(_ r: RunnerInfo) -> String? {
        if let release = r.release, !release.isEmpty {
            return release.split(separator: "-").last.map(String.init) ?? release
        }
        return r.version
    }

    /// The row's tooltip: everything it knows, a line each.
    public static func rowTip(_ r: RunnerInfo, now: Date, running: Int) -> String {
        var lines = [r.name + (r.isSelf ? " (this Mac's runner)" : ""), stateLine(r, now: now)]
        if let version = r.version { lines.append("Version \(version)") }
        if let started = r.startedAt { lines.append("Started \(started.formatted(date: .abbreviated, time: .shortened))") }
        if let seen = r.lastSeenAt, !r.isSelf { lines.append("Last heard from \(span(from: seen, to: now)) ago") }
        if running > 0 { lines.append(running == 1 ? "1 thread running" : "\(running) threads running") }
        return lines.joined(separator: "\n")
    }

    /// The icon's tooltip: "Runners", then how many are up and which aren't.
    public static func tooltip(_ runners: [RunnerInfo]) -> String {
        var lines = ["Runners"]
        let down = runners.filter { state($0) == .offline }.map(\.name)
        let updating = runners.filter { state($0) == .updating }.map(\.name)
        if down.isEmpty {
            lines.append(runners.count == 2 ? "Both online" : "All \(runners.count) online")
        } else {
            lines.append("\(runners.count - down.count) of \(runners.count) online")
            lines.append(list(down) + " offline")
        }
        if !updating.isEmpty { lines.append(list(updating) + (updating.count == 1 ? " is updating" : " are updating")) }
        return lines.joined(separator: "\n")
    }

    /// The threads running on a runner: its own sidebar rows (`runnerId`
    /// nil for this Mac's) in the Running section's order.
    public static func running(on r: RunnerInfo, in running: [ThreadSummary]) -> [ThreadSummary] {
        running.filter { r.isSelf ? $0.runnerId == nil || $0.runnerId == r.id : $0.runnerId == r.id }
    }

    /// "12s", "4m", "3h", "2d", as the website says them.
    public static func span(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start).rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
