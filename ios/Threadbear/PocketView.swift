import CoreLocation
import MapKit
import SwiftUI
import ThreadbearKit

/// The Pocket: a Wallet-style deck of the cards agents filed for when Mike's
/// out. Reads the cards AppModel saved on the phone, so it needs no signal.
struct PocketView: View {
    enum Next { case thread(String), add }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var places = PocketPlaces()
    @State private var chosen: String?
    @State private var showing: PocketCard?
    var then: (Next) -> Void

    var body: some View {
        let deck = PocketDeck.ordered(model.pocket, here: places.here)
        let open = deck.first { $0.id == chosen }?.id ?? deck.last?.id
        NavigationStack {
            Group {
                if deck.isEmpty {
                    ContentUnavailableView {
                        Label { Text("Nothing in your pocket") } icon: { BearView(pose: .sit, size: 44) }
                    } description: {
                        Text("Ask a thread to pop something in here.")
                    }
                } else {
                    ScrollView {
                        // Negative spacing is the overlap: each card's foot
                        // tucks under the next one, as in Wallet.
                        VStack(spacing: -14) {
                            ForEach(Array(deck.enumerated()), id: \.element.id) { index, card in
                                row(card, index: index, isOpen: card.id == open)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Pocket")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { go(.add) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Add a card")
                }
            }
        }
        .task(id: model.pocket.map(\.id)) {
            if !model.isFake { places.look(for: model.pocket) }
        }
        // `-ThreadbearPocketBig` (Debug only, for screenshots): the front card, filling the screen.
        .onChange(of: deck.last?.id, initial: true) { _, _ in
            #if DEBUG
            if CommandLine.arguments.contains("-ThreadbearPocketBig"), showing == nil { showing = deck.last }
            #endif
        }
        .fullScreenCover(item: $showing) { card in
            PocketBigCard(card: card) { go(.thread($0)) }
        }
    }

    private func row(_ card: PocketCard, index: Int, isOpen: Bool) -> some View {
        PocketCardView(card: card, isOpen: isOpen, isHere: places.here.contains(card.id), depth: index)
            .zIndex(Double(index))
            .onTapGesture {
                if isOpen { showing = card } else {
                    withAnimation(.spring(duration: 0.35)) { chosen = card.id }
                }
            }
            .contextMenu {
                Button { UIPasteboard.general.string = card.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                if let thread = card.threadId {
                    Button { go(.thread(thread)) } label: { Label("Open thread", systemImage: "bubble.left") }
                }
                Button(role: .destructive) { model.removePocketCard(card) } label: { Label("Remove", systemImage: "trash") }
            }
    }

    private func go(_ next: Next) {
        then(next)
        showing = nil
        dismiss()
    }
}

private struct PocketCardView: View {
    var card: PocketCard
    var isOpen: Bool
    var isHere: Bool
    var depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isHere {
                    Label("here", systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let source = card.source {
                    Text(source)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if isOpen {
                Text(card.text)
                    .font(.title3.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: isOpen ? 300 : 80, alignment: .topLeading)
        // A solid fill, as the cards overlap, a touch lighter towards the front.
        .background {
            ZStack {
                Color(.secondarySystemBackground)
                Color.primary.opacity(min(0.02 * Double(depth), 0.1))
            }
        }
        .clipShape(.rect(cornerRadius: 15))
        .shadow(color: .black.opacity(0.18), radius: 6, y: -2)
        .contentShape(.rect(cornerRadius: 15))
    }
}

/// One card filling the screen, black on white, to read from or hold up to
/// someone across a counter.
private struct PocketBigCard: View {
    var card: PocketCard
    var openThread: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(card.text)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.black)
                // A long card shrinks to fit rather than scrolling off.
                .minimumScaleFactor(0.35)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
            HStack {
                Button("Done") { dismiss() }
                Spacer()
                Button("Copy") { UIPasteboard.general.string = card.text }
                if let thread = card.threadId {
                    Spacer()
                    Button("Open thread") { openThread(thread) }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 12)
        }
        .tint(.blue)
        .background(Color.white.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        // The screen stays on while someone's copying the address down.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Which cards' places are nearby. Asks for location only when a card has a
/// place, and only while the app's open. The location is used here and in
/// Apple's map search; it's never sent to Threadbear's backend or a runner.
@MainActor @Observable
final class PocketPlaces: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var here: Set<String> = []
    private let manager = CLLocationManager()
    private var cards: [PocketCard] = []
    /// As close as a search result has to be for the card to count as here.
    private let nearby: CLLocationDistance = 250

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func look(for cards: [PocketCard]) {
        self.cards = cards.filter { $0.place != nil }
        guard !self.cards.isEmpty else { here = []; return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !cards.isEmpty, [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let cards = cards
        Task {
            var found: Set<String> = []
            for card in cards {
                if let place = card.place, await Self.isNear(place, location, within: nearby) { found.insert(card.id) }
            }
            withAnimation { here = found }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix, so no card is marked here; the deck is fine without.
    }

    private static func isNear(_ place: String, _ location: CLLocation, within distance: CLLocationDistance) async -> Bool {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)
        // No signal just means no answer.
        guard let response = try? await MKLocalSearch(request: request).start() else { return false }
        return response.mapItems.contains { $0.placemark.location.map { $0.distance(from: location) <= distance } ?? false }
    }
}
