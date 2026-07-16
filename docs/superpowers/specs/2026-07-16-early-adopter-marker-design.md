# Early-Adopter-Marker — Design

**Datum:** 2026-07-16 · **Status:** geplant (für ein kommendes Release, nicht sofort)
**Ziel in einem Satz:** Beim ersten Start unsichtbar festhalten, ab welchem Build ein
Nutzer die App zum ersten Mal hatte — damit wir beim späteren **Pro-Paywall-Launch**
Bestandsnutzer sauber **grandfathern** (Pro dauerhaft frei) können.

## Nicht-Ziele (bewusst NICHT in diesem Schritt)
- **Kein Gating, keine Paywall, keine Entitlement-Änderung.** `DormantEntitlement`
  bleibt unverändert (alle weiterhin Pro). Dieses Release **schreibt nur den Marker**.
- Kein Backend, kein Konto. Der Marker ist **gerätelokal** (bewusste Grenze, siehe
  „Edge Cases").
- Keine UI, kein „Was ist neu"-Eintrag (unsichtbar für den Nutzer).

## Kernidee
Ein einmalig geschriebener Wert `firstSeenVersionCode` (int) in `AppConfig`:
- **Bestandsnutzer** (App vor diesem Marker-Release schon benutzt) → Sentinel **`0`**
  = „pre-marker, grandfathered".
- **Frischinstallation** dieses oder eines späteren Builds → der **aktuelle
  versionCode** dieses Builds.

Beim späteren Paywall-Launch entscheidet allein die Schwelle:
`istGrandfathered = firstSeen != null && firstSeen < PAYWALL_VERSIONCODE`.
`0 < paywall` ⇒ Bestandsnutzer immer frei; wer zwischen Marker- und Paywall-Release
frisch installiert, hat `firstSeen < paywall` ⇒ ebenfalls frei (bewusst großzügig;
die genaue Schwelle wird **erst beim Paywall-Release** gesetzt).

## „War schon mal da?"-Erkennung — ohne Extra-Store-Probe
`AppConfig` trägt bereits zwei verlässliche Signale, die auf einer echten
Frischinstallation `false`/leer sind:
- `disclaimerAccepted == true` (der Erst-Start-Disclaimer ist ein harter First-Run-Gate)
- `lastSeenVersion.isNotEmpty` („Was ist neu?" wurde schon gesehen)

`wasUsedBefore = disclaimerAccepted || lastSeenVersion.isNotEmpty`.
Der Stamp wird **beim App-Load ausgewertet, bevor** der Disclaimer angezeigt wird —
also ist bei einer echten Frischinstallation `wasUsedBefore == false` → aktueller
versionCode; bei einem Update eines Bestandsnutzers `== true` → `0`.

## Änderungen im Detail

### 1. Reine Logik (TDD zuerst) — neue Datei `lib/src/early_adopter.dart`
```dart
/// Grandfather-Marker: den versionCode festhalten, ab dem ein Nutzer die App
/// zum ersten Mal hatte. Sentinel 0 = Bestandsnutzer vor Einführung des Markers.
/// Rein, ohne Plattform-Abhängigkeit; die Quelle des versionCode wird injiziert.
int resolveFirstSeenVersionCode({
  required int? stored,          // bereits gespeicherter Wert (null = noch nie)
  required bool wasUsedBefore,   // disclaimerAccepted || lastSeenVersion.isNotEmpty
  required int currentVersionCode,
}) {
  if (stored != null) return stored;        // idempotent — nie überschreiben
  return wasUsedBefore ? 0 : currentVersionCode;
}

/// Später beim Paywall-Launch verwendet (jetzt schon mitliefern + testen, damit
/// die Semantik dokumentiert/fixiert ist — noch NICHT verdrahtet):
bool isGrandfathered(int? firstSeen, {required int paywallVersionCode}) =>
    firstSeen != null && firstSeen < paywallVersionCode;
```

### 2. `AppConfig` (`lib/src/profiles.dart`) — Feld nach dem Muster von `languageMode`
- Feld: `final int? firstSeenVersionCode;` (nullable; `null` = noch nicht gestempelt)
- Konstruktor: `this.firstSeenVersionCode,` (Default `null`)
- `copyWith`: Parameter `int? firstSeenVersionCode` +
  `firstSeenVersionCode: firstSeenVersionCode ?? this.firstSeenVersionCode`
  (nur null→Wert nötig; das Standard-copyWith-Caveat ist ok, wir setzen genau einmal)
- `toJson`: `'firstSeenVersionCode': firstSeenVersionCode` (null bleibt null)
- `fromJson`: `firstSeenVersionCode: j['firstSeenVersionCode'] is int
      ? j['firstSeenVersionCode'] as int : null`

### 3. Verdrahtung in `main.dart` (einmalig beim Init, nach dem Laden der `AppConfig`)
Direkt nach dem Config-Load, bevor die UI/der Disclaimer greift:
```dart
if (cfg.firstSeenVersionCode == null) {
  final info = await PackageInfo.fromPlatform();          // bereits importiert
  final current = int.tryParse(info.buildNumber) ?? 0;    // buildNumber == versionCode
  final wasUsedBefore =
      cfg.disclaimerAccepted || cfg.lastSeenVersion.isNotEmpty;
  cfg = cfg.copyWith(
    firstSeenVersionCode: resolveFirstSeenVersionCode(
      stored: null, wasUsedBefore: wasUsedBefore, currentVersionCode: current),
  );
  await <bestehender AppConfig-Save-Pfad>(cfg);   // derselbe, der languageMode persistiert
}
```
Best-effort/robust: Fehler beim Stempeln darf den Start nie blockieren (try/catch,
kein neuer Native-Code im Startpfad — nur vorhandenes `package_info_plus` + Storage).

## Tests (TDD)
- `test/early_adopter_test.dart`:
  - stored==null & !wasUsedBefore → currentVersionCode
  - stored==null & wasUsedBefore → 0
  - stored gesetzt → unverändert (idempotent), egal welche Flags
  - `isGrandfathered`: null→false; 0→true; (paywall-1)→true; paywall→false; (paywall+1)→false
- `AppConfig`-Round-Trip: `firstSeenVersionCode` überlebt toJson/fromJson;
  in altem JSON ohne den Key → `null`.
- Dispatch/Integration (FakeConfig-Store): erster Start stempelt, zweiter überschreibt
  nicht; Bestandsnutzer-Fixture (disclaimerAccepted=true) → 0; Fresh-Fixture → currentCode.

## Docs (CLAUDE.md-Regel)
- **`ARCHITECTURE.md`**: neues `AppConfig`-Feld `firstSeenVersionCode` + Zweck
  (künftiges Grandfathering) in der Persistenz-/Gating-Sektion; kurze Notiz zur
  Paywall-Schwellen-Semantik (`isGrandfathered`, Schwelle = Paywall-versionCode).
- **Kein** README/Pages/fastlane/whats_new-Update (unsichtbares Feature).
- Changelog `<versionCode>.txt`: nur falls dieses Release sonst nichts Sichtbares
  enthält → generischer Eintrag; sonst mit den übrigen Änderungen des Releases gebündelt.

## Edge Cases / bewusste Grenzen
- **Reinstall / neues Gerät / Datenlöschung:** lokaler Marker geht verloren. Passiert es
  VOR dem Paywall-Release → neuer `firstSeen` < paywall → weiterhin frei. Erst ein
  Frisch-Install AB dem Paywall-Release verliert den Bestandsschutz. Inhärente Grenze
  ohne Backend; bei 5 € pragmatisch per Support/Gutschein-Code abfangen.
- **Nutzer überspringt das Marker-Release** und installiert erst beim Paywall-Release
  frisch → sieht aus wie neu. Nicht lösbar ohne Konto; akzeptiert.
- Sentinel `0` braucht keine Sonderbehandlung — `0 < paywall` grandfathert automatisch.

## Rollout
Im **nächsten Release** mitziehen (versionCode wie üblich +1). Reiner Additiv-Change,
kein Migrationsrisiko: altes JSON ohne den Key ⇒ `null` ⇒ wird beim ersten Start des
neuen Builds gestempelt.

## Offene Entscheidung (erst zum Paywall-Launch)
`PAYWALL_VERSIONCODE` und damit die Grandfather-Schwelle. Bis dahin sammelt der Marker
nur Daten; nichts wird gegated.
