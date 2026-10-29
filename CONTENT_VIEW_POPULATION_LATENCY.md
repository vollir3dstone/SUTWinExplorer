# ContentView Private Column Population Latency

**Status: Open — investigation required.**

## Observation

After navigation, the Shell view can visibly display its items before the
adjacent private column is populated, even in folders with only a few items.
The private column is intentionally cleared as soon as navigation starts.

## Current understanding

The private column does not render directly from the Shell's data. It first
queries the current Shell view for displayed filesystem paths by view index
using `IFolderView2::GetItem`, then assigns the resulting names to the WPF list
when their order or contents have changed.
WPF must subsequently lay out and render those rows.

There are two relevant update paths:

1. A navigation outcome schedules a private-column refresh at
   `DispatcherPriority.Background`.
2. If the first query is empty or incomplete and the Shell subsequently
   produces a relevant accessibility notification, the change monitor
   coalesces notifications at `DispatcherPriority.ContextIdle`. The host
   checks the current Shell item count and, if it changed, schedules the
   private-column refresh at `DispatcherPriority.Background`.

These are dispatcher priorities, not fixed waiting periods. Both are below
WPF rendering priority, so other UI work can run before the queued update.
The Shell also displays its own content independently of the private column.
The existing 30-ms timer synchronizes scrolling; it does not schedule item
population.

These steps are **plausible contributors**, not a measured explanation of the
observed delay. We do not yet know how much time is spent waiting for the
Shell notification, queued dispatcher work, the Shell data query, or WPF
layout and rendering. The first navigation-triggered query can already contain
the items; the accessibility-event path is not necessarily involved every time.

## Open investigation

- Measure, for the same navigation, when the Shell's items become visible,
  when the navigation outcome and relevant accessibility notifications arrive,
  when each queued dispatcher operation starts, how long the item count and
  displayed-path queries take, and when the private rows become visible.
- Check both small and larger folders, direct startup and navigation, and
  repeated runs. Record counts and timings rather than personal filenames.
- Determine which update path actually populated the column and whether the
  initial query was empty, partial, or complete.
- Based on the measurements, evaluate whether scheduling or query changes
  improve perceived latency without harming responsiveness, incremental
  loading, filtering, navigation failure handling, or scroll alignment. Do not
  assume changing dispatcher priorities alone fixes the problem.

See [CONTENT_VIEW.md](./CONTENT_VIEW.md) for the current behavior, event
subscriptions, synchronization details, and known limitations.
