// Kiroshi Smart Targeting Protocol: capability gates.
//
// Each gate states whether a targeting mechanism is available on the player's build, and
// each has a safe direction. They are switches over capability, not over taste:
//
//   E-STAT   whether the faction axis is enforced or only drawn on the overlay
//   E-TRACK  whether a protocol switch binds to the weapon already in hand
//   E-IGNORE whether denied targets are routed through the look-at ignore list
//
// The three gates are independent. Turning E-STAT or E-TRACK off narrows the mod to
// weapon-side body-part policy plus a read-only IFF overlay, which needs no gate at all
// and stays fully playable. Every gate below carries the symptom that means it is set
// wrong for the build in front of it.
//
// Backing store is Native Settings (the ModSettings runtimeProperty protocol used
// throughout the reference corpus, e.g. Wannabe Edgerunner Config.reds). That framework
// persists its own file outside the save, which is the right scope: whether a mechanism
// works is a fact about the installed game and mod stack, not about a playthrough, so it
// has to survive starting a new game. With the framework absent the annotations are inert
// metadata and `new KSTPGateConfig()` hands back the compiled defaults below, which are
// the shipping configuration.

module KSTP.Core

// Labels below are literal display strings, not loc keys. This mod ships no .archive and
// has no WolvenKit pack step, so a custom loc key has nothing to resolve against and Mod
// Settings would render the raw key ("KSTP-Gate-FactionAxis") straight into the menu. A
// literal string is passed through unchanged when it is not a known key, which is what the
// shipping corpus relies on where it uses plain English (Custom Map Markers config.reds,
// "Minimap config"). Vanilla keys are still keys and still resolve; see the
// "UI-Settings-KeyBindings" category in UI/Settings.reds.
//
// The category string is duplicated verbatim in UI/Settings.reds (multiEntityADS) so both
// land in one group. Mod Settings groups on the rendered string, so the two must match
// character for character; change one, change the other.
public class KSTPGateConfig {

  public static func Get() -> ref<KSTPGateConfig> {
    return new KSTPGateConfig();
  }

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug")
  @runtimeProperty("ModSettings.category.order", "900")
  @runtimeProperty("ModSettings.displayName", "Enforce the faction axis")
  @runtimeProperty("ModSettings.description", "ON suppresses locks on denied targets. OFF colors the overlay by protocol but never blocks a lock, which is useful for seeing what a protocol would refuse without changing how the weapon behaves. Leave it on unless the overlay marks a target refused and the weapon locks it anyway.")
  // Controls whether the faction axis is enforced or only displayed.
  //
  // ON: Enforcement/Faction.reds applies SmartGunTimeToLock*ComponentMultiplier
  // modifiers to the StatsObjectID of every NPC the active protocol refuses. An
  // inflated multiplier holds that NPC at gamesmartGunTargetState.Locking (2) and stops
  // it reaching Locked (3) (orphans.script:8702); permitted NPCs lock at vanilla speed.
  // This is the only per-candidate control available from redscript, because
  // TargetingSystem is 'abstract final importonly' (orphans.script:22381) and exposes no
  // acquisition veto.
  //
  // OFF: faction data is still classified and colored on the overlay, and Faction.reds
  // applies nothing to any NPC.
  //
  // The mechanism prevents a lock and cannot undo one that has already completed, so a
  // target acquired before it became denied stays locked until the player breaks the
  // lock. Turn this off if the overlay marks a target as refused and the gun locks it
  // anyway from a standing start.
  public let factionAxisEnabled: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug")
  @runtimeProperty("ModSettings.category.order", "900")
  @runtimeProperty("ModSettings.displayName", "Bind protocol changes immediately")
  @runtimeProperty("ModSettings.description", "ON pushes a protocol change to the weapon straight away. OFF waits for the next weapon draw. Turn it off only if switching protocol mid-fight misbehaves on your build.")
  // Controls when a protocol switch is treated as bound to the weapon already in hand.
  //
  // ON: the switch takes effect at once. The handler reads the SmartGunTrack* stats from
  // the held weapon's itemData stats object (weapon:GetItemData():GetStatsObjectID(), not
  // the entity) and re-reads them while a lock is in flight, so clearing
  // SmartGunTrackHeadComponents moves a running lock off the head and onto the next
  // permitted component with no holster, no re-equip and no EnableSmartGunHandlerEvent
  // bounce.
  //
  // OFF: callers assume the new policy binds from the next acquisition and the UI does
  // not tell the player the switch has already landed. Nothing is applied differently;
  // only the promise changes.
  //
  // Turn this off if switching protocol mid-fight leaves the lock sitting on a body part
  // the new protocol forbids until the weapon is holstered and drawn again.
  public let liveStatReread: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug")
  @runtimeProperty("ModSettings.category.order", "900")
  @runtimeProperty("ModSettings.displayName", "Use the look-at ignore list (does not work)")
  @runtimeProperty("ModSettings.description", "Leave this off. It routes denied targets through the look-at ignore list, which the smart-gun handler does not read, and it stands the working mechanism down in the process. Turning it on stops the faction filter working. Kept only so the alternative code path is available to anyone extending the mod.")
  // Controls which route Enforcement uses for a denied target: the look-at ignore list
  // or the time-to-lock inflation described under E-STAT.
  //
  // Leave this off. TargetingSystem.AddIgnoredLookAtEntity (orphans.script:22443) is
  // LookAt-scoped and the smart-gun handler does not consult it. Its vanilla callers are
  // device interaction (deviceBase.script:3837), takedowns (locomotionTakedown.script:13)
  // and mounted-vehicle self-ignore (vehicleComponent.script:2938), none of which touch
  // smart-gun acquisition. An entity on the list still brackets and still reaches a full
  // lock.
  //
  // ON also costs the route that does work: Suppress() clears the time-to-lock modifiers
  // before adding the entity to the ignore list, so a denied target ends up with no
  // suppression at all. The symptom is denied targets locking normally while the overlay
  // reports them as refused.
  public let ignoreListWorks: Bool = false;
}

// A single read of all three, for callers that would otherwise poll KSTPGate once
// per tracked target per frame. Each KSTPGate accessor allocates a config object.
public class KSTPGateState {
  public let factionAxis: Bool;
  public let liveStatReread: Bool;
  public let ignoreList: Bool;
}

public class KSTPGate {

  // True while Enforcement/Faction.reds may apply suppression modifiers to world NPCs.
  // While false, faction data is classified and displayed, and Faction.reds must touch
  // nothing.
  public static func FactionAxisEnabled() -> Bool {
    return KSTPGateConfig.Get().factionAxisEnabled;
  }

  // True while a protocol change pushed to the held weapon takes effect at once. While
  // false, callers assume the new policy binds from the next lock acquisition and must
  // not promise the player otherwise.
  public static func LiveStatReread() -> Bool {
    return KSTPGateConfig.Get().liveStatReread;
  }

  // The look-at ignore-list route. No shipped feature consumes it; this accessor and
  // Describe() are its only readers, so a bug report still shows how it was set.
  public static func IgnoreListWorks() -> Bool {
    return KSTPGateConfig.Get().ignoreListWorks;
  }

  public static func Snapshot() -> ref<KSTPGateState> {
    let cfg: ref<KSTPGateConfig> = KSTPGateConfig.Get();
    let state: ref<KSTPGateState> = new KSTPGateState();
    state.factionAxis = cfg.factionAxisEnabled;
    state.liveStatReread = cfg.liveStatReread;
    state.ignoreList = cfg.ignoreListWorks;
    return state;
  }

  public static func AnyEnabled() -> Bool {
    let state: ref<KSTPGateState> = KSTPGate.Snapshot();
    return state.factionAxis || state.liveStatReread || state.ignoreList;
  }

  // For the startup log line, so a bug report says which gates were on.
  public static func Describe() -> String {
    let state: ref<KSTPGateState> = KSTPGate.Snapshot();
    return s"E-STAT=\(state.factionAxis) E-TRACK=\(state.liveStatReread) E-IGNORE=\(state.ignoreList)";
  }
}
