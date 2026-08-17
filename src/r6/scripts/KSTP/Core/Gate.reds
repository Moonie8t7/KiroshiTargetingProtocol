// Kiroshi Smart Targeting Protocol: capability gates.
//
// Three independent switches over targeting mechanisms: E-STAT (the faction axis is enforced,
// not merely drawn), E-TRACK (a protocol change binds to the weapon already in hand), E-IGNORE
// (denied targets are routed through the look-at ignore list). With E-STAT and E-TRACK off the
// mod reduces to weapon-side body-part policy plus a read-only IFF overlay, which stays playable.
//
// Backing store is Mod Settings, which persists outside the save: gate state is a fact about the
// installed game and mod stack, not about a playthrough. With the framework absent the
// annotations are inert metadata and Get() returns the compiled defaults below, which are the
// shipping configuration. See ADR 0010.

module KSTP.Core

// Compiled gate defaults, overlaid by Mod Settings when that framework is present.
//
// Labels and descriptions are literal display strings, not loc keys: Mod Settings renders them
// verbatim (ADR 0004). The category string is the group identity, since Mod Settings groups on
// the rendered text, so a change to it must be made on every field. Debug groups carry the
// "Debug - " prefix and an order above 900 so they sort below what a player tunes (ADR 0009).
public class KSTPGateConfig {

  public static func Get() -> ref<KSTPGateConfig> {
    return new KSTPGateConfig();
  }

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - experiment gates")
  @runtimeProperty("ModSettings.category.order", "930")
  @runtimeProperty("ModSettings.displayName", "Enforce the faction axis")
  @runtimeProperty("ModSettings.description", "ON suppresses locks on denied targets. OFF colors the overlay by protocol but never blocks a lock, which is useful for seeing what a protocol would refuse without changing how the weapon behaves. Leave it on unless the overlay marks a target refused and the weapon locks it anyway.")
  // E-STAT. ON: Enforcement/Faction.reds applies SmartGunTimeToLock*ComponentMultiplier modifiers
  // to the StatsObjectID of every NPC the active protocol refuses, holding it at
  // gamesmartGunTargetState.Locking (2) short of Locked (3) (orphans.script:8702). OFF: faction
  // data is still classified and coloured on the overlay and Faction.reds applies nothing.
  //
  // This is the only per-candidate control reachable from redscript: TargetingSystem is
  // 'abstract final importonly' (orphans.script:22381) and exposes no acquisition veto. The
  // mechanism prevents a lock and cannot undo one already completed. See ADR 0003.
  public let factionAxisEnabled: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - experiment gates")
  @runtimeProperty("ModSettings.category.order", "930")
  @runtimeProperty("ModSettings.displayName", "Bind protocol changes immediately")
  @runtimeProperty("ModSettings.description", "ON pushes a protocol change to the weapon straight away. OFF waits for the next weapon draw. Turn it off only if switching protocol mid-fight misbehaves on your build.")
  // E-TRACK. ON: the handler reads the SmartGunTrack* stats from the held weapon's itemData stats
  // object (weapon:GetItemData():GetStatsObjectID(), not the entity) and re-reads them while a
  // lock is in flight, so clearing SmartGunTrackHeadComponents moves a running lock onto the next
  // permitted component with no holster, re-equip or EnableSmartGunHandlerEvent bounce. OFF:
  // nothing is applied differently; callers assume the new policy binds from the next acquisition
  // and must not tell the player otherwise.
  public let liveStatReread: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - experiment gates")
  @runtimeProperty("ModSettings.category.order", "930")
  @runtimeProperty("ModSettings.displayName", "Use the look-at ignore list (does not work)")
  @runtimeProperty("ModSettings.description", "Leave this off. It routes denied targets through the look-at ignore list, which the smart-gun handler does not read, and it stands the working mechanism down in the process. Turning it on stops the faction filter working. Kept only so the alternative code path is available to anyone extending the mod.")
  // E-IGNORE. Non-functional route, retained only so the alternative code path stays available.
  // TargetingSystem.AddIgnoredLookAtEntity (orphans.script:22443) is LookAt-scoped and the
  // smart-gun handler does not consult it; its vanilla callers are device interaction
  // (deviceBase.script:3837), takedowns (locomotionTakedown.script:13) and mounted-vehicle
  // self-ignore (vehicleComponent.script:2938). ON also stands down the route that does work:
  // Suppress() clears the time-to-lock modifiers before adding the entity, so a denied target
  // ends up with no suppression at all. See ADR 0003.
  public let ignoreListWorks: Bool = false;
}

// One read of all three gates. Each KSTPGate accessor allocates a config object, so callers that
// would otherwise poll once per tracked target per frame take a snapshot instead.
public class KSTPGateState {
  public let factionAxis: Bool;
  public let liveStatReread: Bool;
  public let ignoreList: Bool;
}

// Read accessors over KSTPGateConfig.
public class KSTPGate {

  // True while Enforcement/Faction.reds may apply suppression modifiers to world NPCs. While
  // false, faction data is classified and displayed and Faction.reds must touch nothing.
  public static func FactionAxisEnabled() -> Bool {
    return KSTPGateConfig.Get().factionAxisEnabled;
  }

  // True while a protocol change pushed to the held weapon takes effect at once. While false,
  // callers assume the new policy binds from the next lock acquisition and must not promise the
  // player otherwise.
  public static func LiveStatReread() -> Bool {
    return KSTPGateConfig.Get().liveStatReread;
  }

  // The look-at ignore-list route. No shipped feature consumes it; this accessor and Describe()
  // are its only readers, so a bug report still shows how it was set.
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

  // Startup log line, so a bug report records which gates were on.
  public static func Describe() -> String {
    let state: ref<KSTPGateState> = KSTPGate.Snapshot();
    return s"E-STAT=\(state.factionAxis) E-TRACK=\(state.liveStatReread) E-IGNORE=\(state.ignoreList)";
  }
}
