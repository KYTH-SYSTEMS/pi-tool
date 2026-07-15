/// Pure connection-session + tab-gating logic (UI-free, unit-testable).
///
/// The app has no persistent SSH socket; "connected" is a validated,
/// remembered session state (set on an explicit "Verbindung herstellen",
/// cleared on profile switch / field edit / connection failure). These helpers
/// decide which bottom-navigation tabs that state unlocks.
library;

/// Bottom-navigation tab indices.
const int kTabVerwaltung = 0;
const int kTabAutomatik = 1;
const int kTabTerminal = 2;
const int kTabDateien = 3;

/// Every tab except Verwaltung(0) needs an active connection — Verwaltung is
/// where the user connects, so it must always stay reachable.
bool isGatedTab(int tab) => tab != kTabVerwaltung;

/// Whether [tab] may be shown given the current [connected] state.
bool tabAllowed(int tab, {required bool connected}) =>
    connected || !isGatedTab(tab);

/// Tab to fall back to when the session drops (disconnect / profile switch):
/// a gated tab returns to Verwaltung; Verwaltung stays put.
int tabAfterDisconnect(int currentTab) =>
    isGatedTab(currentTab) ? kTabVerwaltung : currentTab;
