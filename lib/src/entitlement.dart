/// Freemium gating for the one-time "Pro" unlock. Kept Flutter-free + pure so
/// the gating decisions are unit-testable. The Play Billing wiring lives behind
/// [EntitlementService] and is plugged in at launch; until then
/// [DormantEntitlement] keeps everything unlocked so current users lose nothing.
library;

/// The features behind the Pro unlock. Everything not listed here stays free
/// (connect, detect, status, updates, install, live status, reboot, web UIs).
enum ProFeature { backups, console, cleanup, multiPi }

/// Whether [feature] is locked for a user with entitlement [isPro]. (All Pro
/// features gate identically today; the enum keeps a single source of truth for
/// lock badges and future per-feature tiers.)
bool isFeatureLocked(ProFeature feature, {required bool isPro}) => !isPro;

/// Free users may configure at most this many Pi profiles.
const int kFreeProfileLimit = 1;

/// Whether adding another Pi profile is blocked (free + already at the limit).
bool isAddProfileLocked({required bool isPro, required int profileCount}) =>
    !isPro && profileCount >= kFreeProfileLimit;

/// Source of the user's Pro entitlement plus the purchase actions. The real
/// implementation (Play Billing via `in_app_purchase`) is added at launch.
abstract class EntitlementService {
  /// Whether the Pro unlock is currently owned.
  Future<bool> isPro();

  /// Launches the purchase flow; resolves true when Pro was granted.
  Future<bool> buyPro();

  /// Re-checks past purchases (Play "restore"); resolves true if Pro is owned.
  Future<bool> restore();
}

/// Pre-launch default: everyone is Pro (gating dormant). Swapped for the Play
/// Billing implementation when the app goes live, so the current sideloaded
/// users keep every feature.
class DormantEntitlement implements EntitlementService {
  const DormantEntitlement();
  @override
  Future<bool> isPro() async => true;
  @override
  Future<bool> buyPro() async => true;
  @override
  Future<bool> restore() async => true;
}
