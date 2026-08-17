// Kiroshi Smart Targeting Protocol: faction and threat-class enforcement.
//
// Provides KSTPFaction, the static facade named in docs/ARCHITECTURE.md, over the
// KSTPFactionSystem ScriptableSystem that owns the ledger of touched entities.
//
// TargetingSystem is 'abstract final importonly' (orphans.script:22381) and exposes no
// per-candidate veto, so denial is indirect. Route A, gated on KSTPGate.FactionAxisEnabled(),
// inflates SmartGunTimeToLock*ComponentMultiplier on the denied NPC's StatsObjectID to hold it at
// gamesmartGunTargetState.Locking (orphans.script:8702); see ADR 0003. It is target-scoped, so
// every smart weapon in the world is impaired against that NPC, not only the player's. Route B,
// gated on KSTPGate.IgnoreListWorks(), calls TargetingSystem.AddIgnoredLookAtEntity
// (orphans.script:22443): observer-scoped, but LookAt-scoped and unread by the smart-gun handler,
// so it ships off and remains as the documented alternative. Both routes also require
// KSTPPolicySystem.FactionAxisAvailable() (Core/Policy.reds KSTP_FactionAxisMinTier, ADR 0007),
// and both are undone by ClearAll().
//
// Depends on KSTP.Core; UI/Overlay.reds supplies the per-frame smart-gun payload; Codeware
// supplies the spawn hook where installed.

module KSTP.Enforcement

import KSTP.Core.*

// -----------------------------------------------------------------------------
// Public facade
// -----------------------------------------------------------------------------

// Forwards the per-frame smart-gun payload from the crosshair controller's own OnSmartGunParams,
// wrapped in UI/Overlay.reds. KSTPFactionSystem registers no blackboard listener of its own; see
// HookBlackboard. Declared as a free function rather than on KSTPFaction so UI/Overlay.reds can
// call it after `import KSTP.Enforcement.*` without naming the system type.
public func KSTP_PushSmartGunParams(gi: GameInstance, value: Variant) -> Void {
  let sys: ref<KSTPFactionSystem> = KSTPFactionSystem.Get(gi);
  if !IsDefined(sys) {
    return;
  };
  sys.OnSmartGunParams(value);
}

// Static entry points for enforcement. Every one tolerates a missing system, a closed gate and a
// tier below KSTP_FactionAxisMinTier().
public class KSTPFaction {

  // Per-NPC-spawn entry point. Must stay cheap: the gate check is first and it is a plain Mod
  // Settings bool read, so with the gate off this costs one branch per NPC.
  public final static func OnNPCSpawned(puppet: ref<ScriptedPuppet>) -> Void {
    if !KSTPGate.FactionAxisEnabled() {
      return;
    };
    if !IsDefined(puppet) {
      return;
    };
    let sys: ref<KSTPFactionSystem> = KSTPFactionSystem.Get(puppet.GetGame());
    if !IsDefined(sys) {
      return;
    };
    sys.m_spawnHits += 1;
    if KSTPLog.DebugEnabled() && (sys.m_spawnHits == 1 || sys.m_spawnHits % 200 == 0) {
      KSTPLog.Debug(s"spawn hook: \(sys.m_spawnHits) NPC(s) seen");
    };
    // Unconditional: EvaluateOne discards the entity while unarmed or below tier, and the later
    // sweep must still be able to reach this NPC.
    sys.TrackKnown(puppet.GetEntityID());
    sys.EvaluateOne(puppet);
  }

  // Re-runs the decision over every entity that can matter. Callers must invoke it on every
  // protocol change, every IsArmed() flip and every attitude change that could stale a verdict:
  // the per-frame driver stops updating the instant the smart weapon is holstered or swapped,
  // which is when the release path has to run. Idempotent, and safe with the gate off, with
  // nothing tracked, before the player exists, and when called twice in a row.
  //
  // The world is never swept. The set walked is (entities already touched) + (entities on the
  // live smart-gun lock list). The live list comes off blackboard
  // UI_ActiveWeaponData.SmartGunParams (blackboardDefinitions.script:1601), payload
  // smartGunUIParameters.targets (orphans.script:54420-54460), the same read
  // hud_panzer.script:130-132 performs.
  public final static func Reevaluate(gi: GameInstance) -> Void {
    let sys: ref<KSTPFactionSystem> = KSTPFactionSystem.Get(gi);
    if !IsDefined(sys) {
      return;
    };
    // The off state includes restoring what a previous on state applied; a bare return here
    // strands modifiers on a downgrade or an unequip.
    if !KSTPGate.FactionAxisEnabled() || !sys.AxisAvailable() {
      sys.ReleaseAll();
      return;
    };
    sys.SweepKnown();
    sys.ReevaluateTracked();
  }

  // Restores every entity this system has touched. Ungated: teardown that refused to run because
  // the feature is already off would strand modifiers on live NPCs. Must be called on gate-off,
  // on a protocol change to one without faction filtering, on cyberware unequip or downgrade
  // below KSTP_FactionAxisMinTier(), and at session end. Idempotent and cheap when nothing is
  // tracked, so a caller that cannot tell whether anything was applied should call it anyway.
  public final static func ClearAll(gi: GameInstance) -> Void {
    let sys: ref<KSTPFactionSystem> = KSTPFactionSystem.Get(gi);
    if !IsDefined(sys) {
      return;
    };
    sys.ReleaseAll();
  }
}

// -----------------------------------------------------------------------------
// State holder
// -----------------------------------------------------------------------------

// Durable home for the touched-entity ledger behind KSTPFaction's static surface. A
// ScriptableSystem supplies persistent fields, an OnDetach for session end and an OnRestored for
// the reload case.
public class KSTPFactionSystem extends ScriptableSystem {

  // Entities currently carrying route-A lock-time inflation.
  private persistent let m_statSuppressed: array<EntityID>;

  // Every route-A modifier handle handed to StatsSystem, plus the entity each one went on to,
  // index-parallel. Release uses RemoveModifier against these handles and takes back exactly what
  // was applied; RemoveAllModifiers (orphans.script:16955) strips every non-saved modifier on the
  // stat regardless of origin, including another mod's or a quest effector's.
  //
  // Not persistent: a ref<gameStatModifierData> is not serializable, and non-saved AddModifier
  // modifiers (orphans.script:16943, against AddSavedModifier at :16947) do not survive a load,
  // so no stale handle can outlive its modifier.
  private let m_statMods: array<ref<gameStatModifierData>>;
  private let m_statModOwners: array<EntityID>;

  // Entities currently on the player's route-B look-at ignore list.
  private persistent let m_ignoreSuppressed: array<EntityID>;

  // The component-class set the current route-A modifier batch was built from, indexed by
  // KSTPTargetClass ordinal. A different wanted set tears the whole batch down and rebuilds it
  // rather than patching per entity.
  private persistent let m_appliedClasses: array<Bool>;

  private let m_weaponBlackboard: ref<IBlackboard>;
  private let m_smartGunListener: ref<CallbackHandle>;

  // Change detection for the blackboard tick. SmartGunParams is rewritten every frame while a
  // smart weapon is up, so the bookkeeping pass runs only when the tracked ID set changes, plus a
  // slow heartbeat so a pure attitude flip is still noticed.
  private let m_lastLockSet: array<EntityID>;
  private let m_heartbeat: Int32;

  // Diagnostic only. The Codeware call surface HookSpawnCallback uses (n"Entity/Attach",
  // EntityTarget.Type, EntityLifecycleEvent.GetEntity) appears nowhere in the 2.31 dump, so this
  // counter is what tells a bug report whether the hook fires at all.
  private let m_spawnHits: Int32;

  // Every puppet the spawn hook has reported, whether or not it could be acted on at the time.
  // EvaluateOne requires policy.IsArmed(), which is rarely true at the moment an NPC streams in,
  // so recording is unconditional and cheap and the decision is deferred to SweepKnown().
  private let m_known: array<EntityID>;


  public final static func Get(gi: GameInstance) -> ref<KSTPFactionSystem> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"KSTP.Enforcement.KSTPFactionSystem") as KSTPFactionSystem;
  }

  // Whether the installed coprocessor reaches KSTP_FactionAxisMinTier (Core/Policy.reds).
  // Distinct from KSTPGate.FactionAxisEnabled(), which records whether the mechanism works on this
  // build at all: both must hold before anything is suppressed, and either going false is a
  // release rather than a bare return. False with no policy system.
  public final func AxisAvailable() -> Bool {
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(this.GetGameInstance());
    return IsDefined(policy) && policy.FactionAxisAvailable();
  }

  private func OnDetach() -> Void {
    this.ReleaseAll();
    this.UnhookBlackboard();
  }

  // A load drops every non-saved stat modifier (AddModifier, orphans.script:16943, not
  // AddSavedModifier at :16947), so the world is clean while the persistent ID ledger is not and
  // m_statMods is already empty. ReleaseAll() issues no native calls here; it resets the ledger.
  private func OnRestored(saveVersion: Int32, gameVersion: Int32) -> Void {
    this.ReleaseAll();
  }

  private final func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    this.HookBlackboard(request.owner.GetGame());
    this.HookSpawnCallback();
  }

  private final func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    this.ReleaseAll();
    this.UnhookBlackboard();
  }

  // ---------------------------------------------------------------------------
  // Spawn hook
  // ---------------------------------------------------------------------------

  // n"Entity/Attach", EntityTarget.Type(), EntityLifecycleEvent and its GetEntity() accessor are
  // Codeware symbols, absent from the 2.31 game dump and so uncheckable against it. The @if guard
  // degrades a missing Codeware to the fallback at the bottom of this file; a renamed Codeware
  // symbol becomes a compile error for users who do have Codeware.
  @if(ModuleExists("Codeware"))
  private final func HookSpawnCallback() -> Void {
    GameInstance.GetCallbackSystem()
      .RegisterCallback(n"Entity/Attach", this, n"OnEntityAttached")
      .AddTarget(EntityTarget.Type(n"ScriptedPuppet"))
      .SetLifetime(CallbackLifetime.Session);
  }

  @if(!ModuleExists("Codeware"))
  private final func HookSpawnCallback() -> Void {
    // Without Codeware the spawn signal arrives through the @wrapMethod(ScriptedPuppet)
    // OnGameAttached hook at the bottom of this file.
  }

  @if(ModuleExists("Codeware"))
  private cb func OnEntityAttached(event: ref<EntityLifecycleEvent>) -> Void {
    let puppet: ref<ScriptedPuppet> = event.GetEntity() as ScriptedPuppet;
    if IsDefined(puppet) {
      KSTPFaction.OnNPCSpawned(puppet);
    };
  }

  // ---------------------------------------------------------------------------
  // Live lock list
  // ---------------------------------------------------------------------------

  // Resolves the blackboard handle that CollectLockedTargets polls with GetVariant. No listener is
  // registered: RegisterDelayedListener* never delivers to a ScriptableSystem on this build, since
  // the delayed queue is drained by ink game controller UI traversal and every call site in the
  // 2.31 dump sits on one. Per-frame delivery comes from UI/Overlay.reds, which wraps the
  // crosshair controller's own OnSmartGunParams and calls KSTP_PushSmartGunParams.
  private final func HookBlackboard(gi: GameInstance) -> Void {
    if IsDefined(this.m_weaponBlackboard) {
      return;
    };
    this.m_weaponBlackboard = GameInstance.GetBlackboardSystem(gi).Get(GetAllBlackboardDefs().UI_ActiveWeaponData);
  }

  private final func UnhookBlackboard() -> Void {
    this.m_smartGunListener = null;
    this.m_weaponBlackboard = null;
  }

  // Per-frame driver, called from UI/Overlay.reds through KSTP_PushSmartGunParams. Decides every
  // candidate the weapon is currently showing, then runs the throttled bookkeeping pass. A closed
  // gate and a tier below KSTP_FactionAxisMinTier() both release the applied batch rather than
  // returning: this is the path a mid-session gate flip or coprocessor downgrade arrives on.
  public final func OnSmartGunParams(value: Variant) -> Bool {
    if !KSTPGate.FactionAxisEnabled() {
      this.ReleaseAll();
      return false;
    };
    // Read once and reused below: KSTPPolicySystem.Get() is a container lookup and this runs
    // every frame a smart weapon is up.
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(this.GetGameInstance());
    if !IsDefined(policy) || !policy.FactionAxisAvailable() {
      this.ReleaseAll();
      return false;
    };
    let params: ref<smartGunUIParameters> = FromVariant<ref<smartGunUIParameters>>(value);
    if !IsDefined(params) {
      return false;
    };
    let current: array<EntityID>;
    let targets: array<smartGunUITargetParameters> = params.targets;
    let i: Int32 = 0;
    while i < ArraySize(targets) {
      if EntityID.IsDefined(targets[i].entityID) {
        ArrayPush(current, targets[i].entityID);
      };
      i += 1;
    };
    // Decided ahead of the heartbeat throttle below: params.targets carries entries at Visible and
    // Targetable as well as Locked (gamesmartGunTargetState, orphans.script:8702), and a
    // time-to-lock modifier cannot undo a lock that has already completed.
    if policy.IsArmed() {
      let protocol: ref<KSTPProtocol> = policy.GetActive();
      if IsDefined(protocol) && protocol.factionFilterEnabled {
        let cand: ref<GameObject>;
        i = 0;
        while i < ArraySize(current) {
          // Remember it either way, so a later sweep covers entities the spawn hook never saw.
          this.TrackKnown(current[i]);
          if !ArrayContains(this.m_statSuppressed, current[i]) && !ArrayContains(this.m_ignoreSuppressed, current[i]) {
            cand = GameInstance.FindEntityByID(this.GetGameInstance(), current[i]) as GameObject;
            if IsDefined(cand) {
              this.Decide(cand, protocol);
            };
          };
          i += 1;
        };

      };
    };

    this.m_heartbeat += 1;
    // SmartGunParams is a per-frame write: the full bookkeeping pass runs only when the tracked
    // set moved, or roughly twice a second so a live attitude change is picked up.
    if this.m_heartbeat < 30 && KSTPFactionSystem.SameIdSet(current, this.m_lastLockSet) {
      return false;
    };
    this.m_heartbeat = 0;
    this.m_lastLockSet = current;
    this.ReevaluateTracked();
    return false;
  }

  private final static func SameIdSet(a: array<EntityID>, b: array<EntityID>) -> Bool {
    if ArraySize(a) != ArraySize(b) {
      return false;
    };
    let i: Int32 = 0;
    while i < ArraySize(a) {
      if !ArrayContains(b, a[i]) {
        return false;
      };
      i += 1;
    };
    return true;
  }

  private final func CollectLockedTargets(out ids: array<EntityID>) -> Void {
    if !IsDefined(this.m_weaponBlackboard) {
      return;
    };
    let params: ref<smartGunUIParameters> = FromVariant<ref<smartGunUIParameters>>(this.m_weaponBlackboard.GetVariant(GetAllBlackboardDefs().UI_ActiveWeaponData.SmartGunParams));
    if !IsDefined(params) {
      return;
    };
    let targets: array<smartGunUITargetParameters> = params.targets;
    let i: Int32 = 0;
    while i < ArraySize(targets) {
      if EntityID.IsDefined(targets[i].entityID) && !ArrayContains(ids, targets[i].entityID) {
        ArrayPush(ids, targets[i].entityID);
      };
      i += 1;
    };
  }

  // ---------------------------------------------------------------------------
  // Decision
  // ---------------------------------------------------------------------------

  // Bookkeeping pass over the entities already touched plus the entities on the live lock list.
  // Re-checks policy, tier and IsArmed itself and releases everything when any of them says the
  // correct state is "nothing suppressed"; suppressing while unarmed would keep route A's
  // allied-NPC collateral running while the player is not holding the gun.
  public final func ReevaluateTracked() -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(gi);
    if !IsDefined(policy) {
      this.ReleaseAll();
      return;
    };
    let protocol: ref<KSTPProtocol> = policy.GetActive();
    if !IsDefined(protocol) || !policy.FactionAxisAvailable() || !policy.IsArmed() {
      if KSTPLog.DebugEnabled() {
        KSTPLog.Debug(s"enforcement idle: protocol=\(IsDefined(protocol)) coprocessorInstalled=\(policy.FactionAxisAvailable()) armed=\(policy.IsArmed()) -> released everything");
      };
      this.ReleaseAll();
      return;
    };
    // Two axes reach this sweep and either alone is enough work to run it. The vehicle verdict is
    // a class decision that must hold with faction filtering off; see ADR 0013.
    if !protocol.factionFilterEnabled && protocol.Allows(KSTPTargetClass.Vehicle) {
      this.ReleaseAll();
      return;
    };

    // Rebuild from scratch when the class set has changed.
    let wanted: array<Bool> = KSTPFactionSystem.WantedClasses(protocol);
    if !KSTPFactionSystem.SameClassSet(wanted, this.m_appliedClasses) {
      this.ReleaseAll();
      this.m_appliedClasses = wanted;
    };

    // 1. Everything already touched: is the verdict still "deny"?
    let tracked: array<EntityID>;
    let live: array<EntityID>;
    let obj: ref<GameObject>;
    let i: Int32 = 0;
    while i < ArraySize(this.m_statSuppressed) {
      ArrayPush(tracked, this.m_statSuppressed[i]);
      i += 1;
    };
    i = 0;
    while i < ArraySize(this.m_ignoreSuppressed) {
      if !ArrayContains(tracked, this.m_ignoreSuppressed[i]) {
        ArrayPush(tracked, this.m_ignoreSuppressed[i]);
      };
      i += 1;
    };
    i = 0;
    while i < ArraySize(tracked) {
      obj = GameInstance.FindEntityByID(gi, tracked[i]) as GameObject;
      if !IsDefined(obj) {
        // Entity is gone; its stats went with it. Drop the bookkeeping, touch nothing.
        this.Forget(tracked[i]);
      } else {
        this.Decide(obj, protocol);
      };
      i += 1;
    };

    // 2. Everything currently on the lock list: does it need suppressing?
    this.CollectLockedTargets(live);
    let trace: Bool = KSTPLog.DebugEnabled();
    let vehicles: Int32 = 0;
    let decided: Int32 = 0;
    let isNew: Bool;
    i = 0;
    while i < ArraySize(live) {
      isNew = !ArrayContains(tracked, live[i]);
      // The extra resolve is paid only while tracing.
      if isNew || trace {
        obj = GameInstance.FindEntityByID(gi, live[i]) as GameObject;
        if IsDefined(obj) {
          if trace && IsDefined(obj as VehicleObject) {
            vehicles += 1;
          };
          if isNew {
            this.Decide(obj, protocol);
            decided += 1;
          };
        };
      };
      i += 1;
    };

    // m_known holds ScriptedPuppets only, so its counts say nothing about cars: this list is the
    // only place a vehicle is visible to enforcement.
    if trace {
      KSTPLog.Debug(s"lock list: \(ArraySize(live)) target(s), \(vehicles) vehicle(s), \(decided) newly decided | protocol=\(protocol.displayName) allowsVEHICLE=\(protocol.Allows(KSTPTargetClass.Vehicle)) factionFilter=\(protocol.factionFilterEnabled)");
    };
  }

  // Record a puppet so a later arm or protocol change can reach it.
  public final func TrackKnown(id: EntityID) -> Void {
    if !EntityID.IsDefined(id) {
      return;
    };
    if !ArrayContains(this.m_known, id) {
      ArrayPush(this.m_known, id);
    };
  }

  // Re-decides every NPC the spawn hook has recorded and drops the ones that streamed out. The
  // proactive half of enforcement: it puts a verdict in place before a lock can form. Runs on arm
  // and protocol changes only, never per frame. EvaluateOne re-checks the gate, the tier and
  // IsArmed itself, so a sweep fired at a bad moment is a no-op rather than an error.
  public final func SweepKnown() -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let live: array<EntityID>;
    let obj: ref<GameObject>;
    let before: Int32 = ArraySize(this.m_statSuppressed) + ArraySize(this.m_ignoreSuppressed);
    let i: Int32 = 0;
    while i < ArraySize(this.m_known) {
      obj = GameInstance.FindEntityByID(gi, this.m_known[i]) as GameObject;
      if IsDefined(obj) {
        ArrayPush(live, this.m_known[i]);
        this.EvaluateOne(obj);
      };
      i += 1;
    };
    let dropped: Int32 = ArraySize(this.m_known) - ArraySize(live);
    this.m_known = live;
    // Counts are split by route: statMod is route A, ignore is route B. With
    // KSTPGate.IgnoreListWorks() off, as shipped, a healthy line reads statMod=N ignore=0.
    KSTPLog.Debug(s"sweep: \(ArraySize(live)) live NPC(s), \(dropped) streamed out, suppression \(before) -> statMod=\(ArraySize(this.m_statSuppressed)) ignore=\(ArraySize(this.m_ignoreSuppressed))");
  }

  // Spawn-time path: the same decision without the enumeration. Only ever adds suppression, so it
  // re-checks the gate and the tier itself and returns rather than releasing when either is false.
  // Release runs through Reevaluate/ClearAll, which the Core/Policy.reds loadout hooks drive on
  // every cyberware change.
  public final func EvaluateOne(obj: ref<GameObject>) -> Void {
    if !KSTPGate.FactionAxisEnabled() {
      return;
    };
    let gi: GameInstance = this.GetGameInstance();
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(gi);
    if !IsDefined(policy) || !policy.FactionAxisAvailable() || !policy.IsArmed() {
      return;
    };
    let protocol: ref<KSTPProtocol> = policy.GetActive();
    if !IsDefined(protocol) || !protocol.factionFilterEnabled {
      return;
    };
    let wanted: array<Bool> = KSTPFactionSystem.WantedClasses(protocol);
    if !KSTPFactionSystem.SameClassSet(wanted, this.m_appliedClasses) {
      this.ReleaseAll();
      this.m_appliedClasses = wanted;
    };
    this.Decide(obj, protocol);
  }

  // Single-entity verdict: permitted entities and vehicles are released, refused puppets are
  // suppressed.
  private final func Decide(obj: ref<GameObject>, protocol: ref<KSTPProtocol>) -> Void {
    if !IsDefined(obj) {
      return;
    };
    let id: EntityID = obj.GetEntityID();
    if !EntityID.IsDefined(id) {
      return;
    };
    // Never touch the player: route A would slow the player's own lockability for anyone shooting
    // at them, route B would delete them from their own look-at set.
    if IsDefined(obj as PlayerPuppet) {
      return;
    };
    if obj.IsDead() {
      this.Release(id);
      return;
    };
    let classification: ref<KSTPClassification> = KSTPClassifier.Classify(obj);
    let known: Bool = IsDefined(classification);
    let reason: Int32;
    let permits: Bool = !known || KSTPClassifier.PermitsCoded(protocol, classification, reason);
    let isVehicle: Bool = known && classification.isVehicle;

    if isVehicle && KSTPLog.DebugEnabled() {
      let outcome: String = "SUPPRESS";
      if permits {
        outcome = "release (permitted)";
      };
      KSTPLog.Debug(s"vehicle seen: aff=\(NameToString(classification.affiliation)) threat=\(EnumInt(classification.threat)) allowsVEHICLE=\(protocol.Allows(KSTPTargetClass.Vehicle)) permits=\(permits) [\(KSTPClassifier.PermitReasonName(reason))] -> \(outcome)");
    };

    if permits {
      this.Release(id);
      return;
    };

    // A refused vehicle is released rather than suppressed: a 1000x time-to-lock multiplier on a
    // car still took a full lock at normal speed, in the same session where the identical
    // inflation held an NPC at Locking. Vehicle exclusion lives on the class mask, which
    // Enforcement/BodyPart.reds enforces by zeroing SmartGunTrackVehicleComponents; the refusal
    // verdict is kept because the IFF overlay reads it to label the car REFUSE. See ADR 0013.
    if isVehicle {
      if KSTPLog.DebugEnabled() {
        KSTPLog.Debug("vehicle refused but not suppressed: exclusion belongs to the class mask; a car reaching here means the track stat did not stop it");
      };
      this.Release(id);
      return;
    };

    this.Suppress(obj);
  }

  // ---------------------------------------------------------------------------
  // Apply / restore
  // ---------------------------------------------------------------------------

  // Puppets only: Decide() releases vehicles before reaching here.
  private final func Suppress(obj: ref<GameObject>) -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let id: EntityID = obj.GetEntityID();

    if KSTPGate.IgnoreListWorks() {
      // Route B: the smart gun does not consult the look-at ignore list, so this suppresses
      // nothing on 2.31. The gate ships off.
      if ArrayContains(this.m_ignoreSuppressed, id) {
        return;
      };
      let player: ref<PlayerPuppet> = GetPlayer(gi);
      if !IsDefined(player) {
        return;
      };
      // Clear route A first, so the same entity is never held down through both mechanisms.
      this.ClearStatSuppression(id);
      GameInstance.GetTargetingSystem(gi).AddIgnoredLookAtEntity(player, id);
      let ignored: array<EntityID> = this.m_ignoreSuppressed;
      ArrayPush(ignored, id);
      this.m_ignoreSuppressed = ignored;
      return;
    };

    if ArrayContains(this.m_statSuppressed, id) {
      return;
    };
    this.ClearIgnoreSuppression(id);
    let stats: ref<StatsSystem> = GameInstance.GetStatsSystem(gi);
    let objID: StatsObjectID = Cast<StatsObjectID>(id);
    let classes: array<Bool> = this.m_appliedClasses;
    let statType: gamedataStatType;
    let data: ref<gameStatModifierData>;
    let landed: Int32 = 0;
    let i: Int32 = 0;
    while i < KSTPTargetClassCount() {
      // m_appliedClasses is the set of classes a permitted target keeps, which is what a faction
      // refusal inflates: every avenue the gun would otherwise use against this NPC.
      if i < ArraySize(classes) && classes[i] {
        statType = KSTPStats.TimeToLockStatFor(IntEnum<KSTPTargetClass>(i));
        if NotEquals(statType, gamedataStatType.Invalid) {
          // The stat is itself a multiplier whose vanilla value is 1.0, so Multiplier lands the
          // effective time-to-lock at SuppressionMultiplier() x vanilla; Additive would add a raw
          // offset instead.
          data = RPGManager.CreateStatModifier(statType, gameStatModifierType.Multiplier, KSTPStats.SuppressionMultiplier());
          if stats.AddModifier(objID, data) {
            // Tracked only once the game has accepted it, so release never targets a modifier
            // that was never applied.
            ArrayPush(this.m_statMods, data);
            ArrayPush(this.m_statModOwners, id);
            landed += 1;
          };
        };
      };
      i += 1;
    };

    // Enter the ledger only if something landed. An entry with no modifier behind it is
    // self-perpetuating: the ArrayContains early-out above makes every later attempt a no-op and
    // the candidate loop skips anything already in the ledger, so the NPC stays marked refused
    // while locking normally.
    if landed == 0 {
      if KSTPLog.DebugEnabled() {
        KSTPLog.Debug(s"suppress FAILED: 0 modifier(s) accepted, not entering the ledger so the next pass retries");
      };
      return;
    };

    let suppressed: array<EntityID> = this.m_statSuppressed;
    ArrayPush(suppressed, id);
    this.m_statSuppressed = suppressed;
  }

  private final func Release(id: EntityID) -> Void {
    this.ClearStatSuppression(id);
    this.ClearIgnoreSuppression(id);
  }

  // Drop bookkeeping without issuing native calls, for entities that no longer exist.
  private final func Forget(id: EntityID) -> Void {
    this.PruneStatMods(id, false);
    let suppressed: array<EntityID> = this.m_statSuppressed;
    ArrayRemove(suppressed, id);
    this.m_statSuppressed = suppressed;
    let ignored: array<EntityID> = this.m_ignoreSuppressed;
    ArrayRemove(ignored, id);
    this.m_ignoreSuppressed = ignored;
  }

  // Takes back exactly the modifiers applied to `id`, and nothing else. RemoveModifier
  // (orphans.script:16949), never RemoveAllModifiers (:16955): the latter strips every non-saved
  // modifier on the named stat regardless of who added it, so sweeping the seven
  // SmartGunTimeToLock* stats of a world NPC would delete a lock-time modifier another mod or a
  // quest effector had applied to the same NPC.
  //
  // `removeNative` false is the entity-is-gone path: the stats object died with the entity, so
  // only the handles are dropped.
  private final func PruneStatMods(id: EntityID, removeNative: Bool) -> Void {
    if ArraySize(this.m_statMods) == 0 {
      return;
    };
    let stats: ref<StatsSystem>;
    let objID: StatsObjectID;
    if removeNative {
      stats = GameInstance.GetStatsSystem(this.GetGameInstance());
      objID = Cast<StatsObjectID>(id);
    };
    let keptMods: array<ref<gameStatModifierData>>;
    let keptOwners: array<EntityID>;
    let i: Int32 = 0;
    while i < ArraySize(this.m_statMods) {
      if this.m_statModOwners[i] == id {
        if removeNative && IsDefined(stats) {
          stats.RemoveModifier(objID, this.m_statMods[i]);
        };
      } else {
        ArrayPush(keptMods, this.m_statMods[i]);
        ArrayPush(keptOwners, this.m_statModOwners[i]);
      };
      i += 1;
    };
    this.m_statMods = keptMods;
    this.m_statModOwners = keptOwners;
  }

  private final func ClearStatSuppression(id: EntityID) -> Void {
    // Prune first and unconditionally: a handle whose ledger entry went missing still has to come
    // off the NPC, so this must not hang off the ArrayContains check.
    this.PruneStatMods(id, true);
    if !ArrayContains(this.m_statSuppressed, id) {
      return;
    };
    let suppressed: array<EntityID> = this.m_statSuppressed;
    ArrayRemove(suppressed, id);
    this.m_statSuppressed = suppressed;
  }

  private final func ClearIgnoreSuppression(id: EntityID) -> Void {
    if !ArrayContains(this.m_ignoreSuppressed, id) {
      return;
    };
    let gi: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(gi);
    if IsDefined(player) {
      GameInstance.GetTargetingSystem(gi).RemoveIgnoredLookAtEntity(player, id);
    };
    // Drop the entry even when the player lookup failed, or a failed lookup pins the ledger open.
    let ignored: array<EntityID> = this.m_ignoreSuppressed;
    ArrayRemove(ignored, id);
    this.m_ignoreSuppressed = ignored;
  }

  // True when nothing is applied and nothing is remembered, so ReleaseAll() has no work to do.
  // Kept to five ArraySize() calls because the gate-off path in OnSmartGunParams runs it every
  // frame a smart weapon is up.
  private final func IsIdle() -> Bool {
    return ArraySize(this.m_statSuppressed) == 0 && ArraySize(this.m_statMods) == 0 && ArraySize(this.m_ignoreSuppressed) == 0 && ArraySize(this.m_appliedClasses) == 0 && ArraySize(this.m_lastLockSet) == 0;
  }

  // Releases what is tracked and leaves the ledger empty. Idempotent by construction: a second
  // call, a call with the gate off, or a call on a system that never applied anything is a cheap
  // no-op. Safe from any teardown path.
  public final func ReleaseAll() -> Void {
    if this.IsIdle() {
      return;
    };
    let pending: array<EntityID> = this.m_statSuppressed;
    let i: Int32 = 0;
    while i < ArraySize(pending) {
      this.ClearStatSuppression(pending[i]);
      i += 1;
    };
    // A modifier handle whose ledger entry went missing still has to come off the NPC it was
    // applied to. Duplicated owners cost one no-op pass each.
    let owners: array<EntityID> = this.m_statModOwners;
    i = 0;
    while i < ArraySize(owners) {
      this.PruneStatMods(owners[i], true);
      i += 1;
    };
    pending = this.m_ignoreSuppressed;
    i = 0;
    while i < ArraySize(pending) {
      this.ClearIgnoreSuppression(pending[i]);
      i += 1;
    };
    // Reset explicitly so a partial failure above cannot leave a phantom entry behind.
    let empty: array<EntityID>;
    this.m_statSuppressed = empty;
    this.m_ignoreSuppressed = empty;
    this.m_statModOwners = empty;
    let noMods: array<ref<gameStatModifierData>>;
    this.m_statMods = noMods;
    let noClasses: array<Bool>;
    this.m_appliedClasses = noClasses;
    let noLive: array<EntityID>;
    this.m_lastLockSet = noLive;
  }

  // ---------------------------------------------------------------------------
  // Class coverage
  // ---------------------------------------------------------------------------

  // Every class, unconditionally, whatever the protocol asks for. A faction refusal means the
  // target may not be locked at all, so it has to close every avenue, including the raw head slot
  // the native handler falls back to when no enabled class matches a candidate
  // (weapon.script:1526, ADR 0006). lockPolicy governs the body-part class mask on the weapon and
  // has no business on the target side; keying this on it made a refusal's strength depend on an
  // unrelated setting, the coupling ADR 0003 and ADR 0006 exist to keep apart. The cost is at most
  // a few no-op modifiers per refused NPC.
  //
  // Consequence: SameClassSet is therefore always true, so m_appliedClasses no longer drives
  // rebuilds and survives only as the "a batch has been populated" flag the empty-array checks
  // elsewhere key on.
  private final static func WantedClasses(protocol: ref<KSTPProtocol>) -> array<Bool> {
    let out: array<Bool>;
    let i: Int32 = 0;
    while i < KSTPTargetClassCount() {
      ArrayPush(out, true);
      i += 1;
    };
    return out;
  }

  private final static func SameClassSet(a: array<Bool>, b: array<Bool>) -> Bool {
    if ArraySize(a) != ArraySize(b) {
      return false;
    };
    let i: Int32 = 0;
    while i < ArraySize(a) {
      // Spelled out: the 2.31 dump declares no OperatorNotEqual(Bool, Bool).
      if a[i] && !b[i] {
        return false;
      };
      if !a[i] && b[i] {
        return false;
      };
      i += 1;
    };
    return true;
  }
}

// Degraded spawn hook for installs without Codeware. NPCPuppet.OnGameAttached calls
// super.OnGameAttached() (NPCPuppet.script:376), so wrapping the ScriptedPuppet override
// (scriptedPuppet.script:483) catches regular NPCs as well as anything else deriving from
// ScriptedPuppet. Costs one gated static call per puppet attach, which is why
// KSTPFaction.OnNPCSpawned checks the gate first.

@if(!ModuleExists("Codeware"))
@wrapMethod(ScriptedPuppet)
protected cb func OnGameAttached() -> Bool {
  let result: Bool = wrappedMethod();
  KSTPFaction.OnNPCSpawned(this);
  return result;
}
