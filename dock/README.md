# BearDock

Dockable, rearrangeable panels for Threadbear, in a package of their own with
a demo app, so dragging and docking can feel right before it goes into the
real window.

`./run.sh` opens the demo. `swift test` runs the layout tests.

## How it works

- **The layout is a tree** (`DockLayout`): splits, horizontal or vertical,
  down to groups of panels shown as tabs. Any depth. After every change it's
  tidied: no empty groups, no one-child splits, and a split directly inside
  another along the same axis is flattened into it. It's `Codable`, so the
  demo saves it between launches.
- **Dragging** a panel's body or its tab lifts it: the panel shrinks to
  about 240 points wide under the pointer, with the spot you grabbed kept
  under it, and leaves a dashed hole behind.
- **Over another panel**, the side you're nearest (within 28% of it) lights
  up: dropping there splits that panel's space in half.
- **In the middle** of a panel a compass appears: dock above, below, left
  or right of it, add as a tab, or swap places. Its caption says which.
- **Along the window's own edge** (the outer 22 points) the panel docks
  across the whole side.
- On drop the ghost flies into its new spot; dropped anywhere else it flies home.
- Dividers between panels drag to resize; × on a tab closes it, and the
  toolbar's menu opens it again.

The feel lives in a few constants at the top of `DockController`
(`edgeBand`, `windowBand`, `ghostWidth`, the springs).

For screenshots without touching the mouse, `BEARDOCK_FREEZE` holds a drag
of Highlights mid-air: `edge`, `compass`, `compass-left`, `window`, or any of
those with `+drop` to let go.
