import AppKit
import CoreImage
import SwiftUI
import ThreadbearCore

/// Settings › Phone & browser: pair the iPhone app (a QR code it scans),
/// open the website signed in, and the list of what's paired, each with
/// Revoke. The runner issues every token (docs/protocol.md, "Devices"); a
/// token is only ever inside the QR code on screen or the link the browser
/// opens, never in this app's state or log.
struct DevicesSettings: View {
    @Environment(AppModel.self) private var app
    @State private var pairingLink: URL?
    @State private var pairing = false
    @State private var opening = false

    var body: some View {
        Form {
            if app.devicesUnsupported {
                Section {
                    Text("This runner is too old to pair phones. It gets it when it next updates.")
                        .foregroundStyle(.secondary)
                }
            } else if app.connection != .connected {
                Section {
                    Text("Not connected to the runner.")
                        .foregroundStyle(.secondary)
                }
            } else if let reason = app.devicesReason {
                Section {
                    Text("Your threads aren't mirrored to Convex yet (\(reason)), so there's nothing for a phone or browser to read.")
                        .foregroundStyle(.secondary)
                    Text("Run ./threadbear setup in the repo, then come back here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    LabeledContent {
                        Button("Show the code…") { pairPhone() }
                            .disabled(pairing)
                            .tip("A code to scan with the Threadbear iPhone app. It pairs the phone with your threads for 90 days.")
                    } label: {
                        HStack(spacing: 6) {
                            Text("iPhone")
                            InfoTip("The Threadbear iPhone app shows your inbox, lets you reply, approve and start threads, and gets a push when a thread needs you. It reads the Convex mirror, so it works while the Mac is asleep.")
                        }
                    }
                    LabeledContent {
                        Button("Open signed in") { openBrowser() }
                            .disabled(opening)
                            .tip("Opens your Threadbear website in \(DefaultBrowser.current()?.name ?? "your browser"), signed in for 90 days")
                    } label: {
                        HStack(spacing: 6) {
                            Text("Browser")
                            InfoTip("Your threads on the web, at \(app.devicesSite ?? "your deployment's .convex.site address"): a link you can paste anywhere. The browser keeps a key of its own; sign another browser in from here too.")
                        }
                    }
                }

                Section {
                    if app.devices.isEmpty {
                        Text(app.devicesLoaded ? "Nothing paired yet" : "Loading…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.devices) { device in
                        DeviceRow(device: device) { app.revoke(device) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Paired")
                        InfoTip("Each phone and browser holds a key of its own, good for 90 days. Revoke signs that one out at its next request; pair it again for a new key.")
                    }
                }
            }

            if let error = app.devicesError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.never)
        .scrollDisabled(true)
        .onAppear { app.loadDevices() }
        .onChange(of: app.connection) { _, state in if state == .connected { app.loadDevices() } }
        // The automation's {"cmd":"settings","pair":true}, for screenshots.
        .onChange(of: app.pairRequest) { pairPhone() }
        .sheet(isPresented: Binding(get: { pairingLink != nil }, set: { if !$0 { pairingLink = nil } })) {
            if let pairingLink { PairPhoneSheet(link: pairingLink) }
        }
    }

    private func pairPhone() {
        guard !pairing else { return }
        pairing = true
        Task {
            pairingLink = await app.pairPhone()
            pairing = false
        }
    }

    private func openBrowser() {
        guard !opening else { return }
        opening = true
        Task {
            await app.openWebsiteSignedIn()
            opening = false
        }
    }
}

/// A paired phone or browser: its icon, name, when it was paired and
/// until when, and Revoke.
private struct DeviceRow: View {
    let device: Device
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.isEmpty ? (device.kind == .browser ? "Browser" : "Phone") : device.name)
                Text(DeviceText.detail(device))
                    .font(.callout)
                    .foregroundStyle(device.expired ? .orange : .secondary)
            }
            Spacer()
            Button("Revoke", action: revoke)
                .tip(device.kind == .browser ? "Sign this browser out. It shows the sign-in page at its next load." : "Unpair this phone. It shows the pairing screen at its next request.")
        }
    }

    private var symbol: String {
        switch device.kind {
        case .phone: "iphone"
        case .browser: "globe"
        case .other: "questionmark.circle"
        }
    }
}

/// A small ⓘ with the explanation in its tooltip, so the form's visible
/// text stays short.
struct InfoTip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .tip(text)
            .accessibilityLabel(text)
    }
}

/// The QR code the iPhone app scans. The link (and the token in it) is in
/// this view's state only while the sheet is up.
struct PairPhoneSheet: View {
    let link: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair your iPhone")
                .font(.title2.weight(.semibold))
            if let image = PairingQR.image(link.absoluteString, side: 220) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .frame(width: 220, height: 220)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Pairing code")
            } else {
                Text("Couldn't draw the code.")
                    .foregroundStyle(.red)
            }
            VStack(spacing: 4) {
                Text("Scan it with the Threadbear app on your iPhone.")
                Text("Don't have the app yet? ios/README.md in the repo says how to put it on your phone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .tip("Close the code. The phone stays paired once it has scanned it.")
        }
        .padding(24)
        .frame(width: 360)
    }
}

/// Draws a link as a QR code, as ios/scripts/pair-qr.swift does (CoreImage,
/// correction level M), scaled with no smoothing so the squares stay crisp.
enum PairingQR {
    static func image(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (side / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
