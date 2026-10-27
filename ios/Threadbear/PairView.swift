import SwiftUI
import ThreadbearKit

/// First run, or after the token's been refused: pair with the Mac by
/// scanning the QR code `tb phone-token` shows.
struct PairView: View {
    @Environment(AppModel.self) private var model
    @State private var pasting = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            BearView(pose: .wave, size: 96)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Text("Pair with your Mac").font(.title2.weight(.semibold))
                Text("On the Mac, run **tb phone-token** and scan the QR code it shows with the Camera.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if let problem = model.authProblem {
                Text("The server stopped accepting this phone's token (\(problem)). Pair again to carry on.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
            }
            if let error = model.lastError {
                Text(error).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.red)
            }
            Spacer()
            // For when the link came another way (Messages to yourself).
            Button("Paste a pairing link") {
                guard let raw = UIPasteboard.general.string, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    model.report(TransportError.server("There's no link on the clipboard."))
                    return
                }
                Task { await model.pair(with: url) }
            }
            .font(.subheadline)
        }
        .padding(32)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var identity: PhoneIdentity?
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            Section("Paired with") {
                LabeledContent("Server", value: model.pairing?.deploymentURL.host() ?? (model.isFake ? "Sample data" : "None"))
                if let identity {
                    LabeledContent("Phone", value: identity.name)
                    if let expires = identity.expiresAt {
                        LabeledContent("Token expires", value: expires.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                ForEach(model.runners) { runner in
                    LabeledContent(runner.name, value: runner.isOnline(at: model.now) ? "Online" :
                                    "Last seen \(RelativeTime.clock(runner.lastSeenAt, now: model.now))")
                }
            }
            Section {
                Button("Unpair this phone", role: .destructive) { confirmUnpair = true }
            } footer: {
                Text("Forgets the token on this phone. Revoke it on the Mac too if the phone's lost.")
            }
        }
        .navigationTitle("Settings")
        .task {
            identity = try? await model.backend?.me()
        }
        .confirmationDialog("Unpair this phone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        }
    }
}
