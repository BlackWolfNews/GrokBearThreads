import AppKit
import SwiftUI

/// The sidebar's small animations, in one place so they share timings and
/// all go quiet together under Reduce Motion (System Settings >
/// Accessibility > Display), where movement becomes a short fade or
/// nothing. Everything here runs on things Mike does many times a day, so
/// each stays well under a quarter of a second and never holds up a click
/// (Mike asked for "a bit of juice" 27 Oct).
@MainActor
enum Juice {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Rows arriving, leaving and gliding between Inbox and Running.
    static var rows: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.32, extraBounce: 0.04)
    }

    /// The selected row's highlight sliding to the next one. Short, as the
    /// arrow keys repeat; none at all under Reduce Motion.
    static var selection: Animation? { reduceMotion ? nil : .snappy(duration: 0.2) }

    /// Hover highlights and buttons fading in and out.
    static let hover = Animation.easeOut(duration: 0.12)

    /// Small things popping in: an unread dot, a badge.
    static var pop: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.55)
    }

    /// A word or number changing in place.
    static var swap: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    /// A thread row turning up or going away. A fade with a slight grow
    /// from its top edge, so the rows around it make room smoothly; a row
    /// changing section also glides there (`sidebarRowSpace`).
    static var row: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    /// Something small appearing: a dot, a badge, a count.
    static var popIn: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity)
    }
}

extension EnvironmentValues {
    /// Shared by a sidebar list's rows: the selected row's highlight is
    /// matched in it, so it slides from row to row, and a thread's rows
    /// are, so one that moves from Running to the Inbox glides up there
    /// rather than vanishing and turning up somewhere else.
    @Entry var sidebarRowSpace: Namespace.ID? = nil
}

extension View {
    /// `matchedGeometryEffect` in the list's space, when there is one.
    @ViewBuilder
    func matched(_ id: String, in space: Namespace.ID?) -> some View {
        if let space {
            matchedGeometryEffect(id: id, in: space)
        } else {
            self
        }
    }

    /// A row's highlight: the faint hover square fading in and out, and the
    /// selected row's grey, matched across the list so it slides.
    func rowHighlight(selected: Bool, hovering: Bool, selectedColor: Color, space: Namespace.ID?) -> some View {
        background {
            ZStack {
                if hovering && !selected {
                    RoundedRectangle(cornerRadius: SidebarMetrics.corner)
                        .fill(SidebarMetrics.hover)
                        .transition(.opacity)
                }
                if selected {
                    RoundedRectangle(cornerRadius: SidebarMetrics.corner)
                        .fill(selectedColor)
                        .matched("selection", in: space)
                }
            }
            .animation(Juice.hover, value: hovering)
        }
    }
}

/// The inbox with nothing in it: the bear, waving once as it rises into
/// place, over the usual note. A small reward for clearing everything.
struct InboxZero: View {
    @State private var shown = false
    @State private var waves = 0

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(6)) {
            Image(nsImage: Bear.image(.wave, side: zoomed(30)))
                .renderingMode(.template)
                .foregroundStyle(.secondary)
                // A couple of quick tilts from its feet, like a wave.
                .keyframeAnimator(initialValue: 0.0, trigger: waves) { bear, angle in
                    bear.rotationEffect(.degrees(angle), anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(0, duration: 0.25)
                        CubicKeyframe(-9, duration: 0.14)
                        CubicKeyframe(7, duration: 0.16)
                        CubicKeyframe(-5, duration: 0.14)
                        CubicKeyframe(0, duration: 0.2)
                    }
                }
                .accessibilityHidden(true)
            Text("Nothing in the inbox.")
                .font(.system(size: TypeScale.sidebarPreview))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, SidebarMetrics.leading)
        .padding(.top, zoomed(14))
        .opacity(shown ? 1 : 0)
        .offset(y: shown || Juice.reduceMotion ? 0 : zoomed(8))
        .onAppear {
            withAnimation(Juice.reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.4).delay(0.1)) { shown = true }
            if !Juice.reduceMotion { waves += 1 }
        }
    }
}
