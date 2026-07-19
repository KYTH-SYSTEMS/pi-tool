/// Early-adopter marker for future Pro **grandfathering**. Records the app build
/// (versionCode) a user first ran, so that when the paywall later goes live,
/// users who had the app while it was free keep Pro free. Pure + Flutter-free;
/// wired via `AppConfig.firstSeenVersionCode` and stamped once at startup.
///
/// NOTE: this release only RECORDS the marker — no gating changes. The
/// [isGrandfathered] decision ships now (fixed + tested) but is used later, when
/// Play Billing replaces DormantEntitlement.
library;

/// Recorded for a user who already used the app BEFORE this marker shipped
/// (detected via existing persisted state), so they are unambiguously
/// grandfathered — `0 < any real paywall versionCode`.
const int kPreMarkerFirstSeen = 0;

/// Resolves the value to persist in `firstSeenVersionCode`. Called once, when
/// [stored] is null (never yet recorded); never overwrites an existing value.
/// [wasUsedBefore] should be true when the app was clearly used before this
/// marker (e.g. the first-run disclaimer was accepted, or a "What's New" was
/// seen) — such users get the pre-marker sentinel; a genuine fresh install
/// records the [currentVersionCode].
int resolveFirstSeenVersionCode({
  required int? stored,
  required bool wasUsedBefore,
  required int currentVersionCode,
}) {
  if (stored != null) return stored; // idempotent
  return wasUsedBefore ? kPreMarkerFirstSeen : currentVersionCode;
}

/// At paywall time: whether a user with [firstSeen] is grandfathered, i.e. had
/// the app before [paywallVersionCode]. The pre-marker sentinel (0) always
/// qualifies. Not wired yet — ships now so the semantics are fixed and tested.
bool isGrandfathered(int? firstSeen, {required int paywallVersionCode}) =>
    firstSeen != null && firstSeen < paywallVersionCode;
