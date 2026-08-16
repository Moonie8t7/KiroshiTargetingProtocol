// Kiroshi Smart Targeting Protocol: faction and threat-class enforcement.
//
// Smart-gun candidate acquisition is native end to end. TargetingSystem is declared
// 'abstract final importonly' (orphans.script:22381), so redscript has no per-candidate
// veto and a denial has to be expressed indirectly. Two routes exist.
//
//   ROUTE A, target-side lock-time inflation. Gated on KSTPGate.FactionAxisEnabled().
//     A large SmartGunTimeToLock*ComponentMultiplier modifier on the denied NPC's own
//     StatsObjectID puts the lock timer for that NPC out of reach and holds it at
//     gamesmartGunTargetState.Locking (orphans.script:8702) while permitted targets lock
//     normally. This is the route that enforces the axis.
//
//   ROUTE B, TargetingSystem look-at ignore list. Gated on KSTPGate.IgnoreListWorks().
//     TargetingSystem.AddIgnoredLookAtEntity(instigator, entityID) (orphans.script:22443)
//     takes the observer as an argument, so it would be observer-scoped and would carry
//     none of route A's collateral. The smart-gun handler does not consult it: the list
//     is LookAt-scoped, and its vanilla callers are device interaction, takedowns and
//     mounted-vehicle self-ignore. The gate ships off and the code path is kept as a
//     documented alternative. Evidence is in docs/research/smart-gun-internals.md.
//
// Route A collateral: the modifier lives on the target, and a stat carries no observer
// parameter. Every smart weapon in the world reads the same target stat, so an allied NPC
// holding one is impaired against exactly the targets the player's protocol refuses.
//
// Both routes additionally require the installed coprocessor to reach the tier that enforces
// the axis (Core/Policy.reds KSTP_FactionAxisMinTier, read through
// KSTPPolicySystem.FactionAxisAvailable). Below that tier this module applies nothing and
// releases anything it already applied, which is the same off-state the gate produces. The
// overlay keeps classifying and coloring targets there, so the axis is legible before it is
// owned.
//
// Both routes are reversible and both are torn down by ClearAll().

module KSTP.Enforcement

import KSTP.Core.*

// -----------------------------------------------------------------------------
// Public facade: the surface named in docs/ARCHITECTURE.md.
// -----------------------------------------------------------------------------

public class KSTPFaction {

  // Per-NPC-spawn entry point. Must stay cheap: the gate check is first and it is a
  // plain Mod Settings bool read, so with the gate off this costs one branch per NPC.
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
    // Record first, unconditionally. EvaluateOne below discards the entity while the player
    // is not armed or is below the tier that enforces the axis, which is the common case;
    // see m_known. Tracking has to survive both of those states or an NPC that spawned
    // before the ripperdoc visit would never be reached by the sweep after it.
    sys.TrackKnown(puppet.GetEntityID());
    sys.EvaluateOne(puppet);
  }

  // Re-run the decision over every entity that can matter. Call this when the active
  // protocol changes, when IsArmed() flips, or when an attitude change makes a previous
  // verdict stale.
  //
  // KSTPPolicySystem must call this on every IsArmed() flip and every protocol change.
  // The blackboard listener that otherwise drives this module stops updating the instant
  // the smart weapon is holstered or swapped, which is when the release path has to run.
  // The call tolerates that pattern: it is idempotent, safe with the gate off, safe with
  // nothing tracked, safe before the player exists, and safe to call twice in a row.
  //
  // Enumeration strategy: the world is never swept. The set walked here is
  //   (entities already touched) + (entities on the live smart-gun lock list).
  // The first half is what has to be restored; the second half is the only set that can
  // be locked right now, so it is the only set worth suppressing. The live list comes off
  // blackboard UI_ActiveWeaponData.SmartGunParams (blackboardDefinitions.script:1601),
  // payload smartGunUIParameters.targets (orphans.script:54420-54460), the same read
  // hud_panzer.script:130-132 performs.
  public final static func Reevaluate(gi: GameInstance) -> Void {
    let sys: ref<KSTPFactionSystem> = KSTPFactionSystem.Get(gi);
    if !IsDefined(sys) {
      return;
    };
    // Gate off, or an installed tier below KSTP_FactionAxisMinTier(), both mean "be in the
    // off state", which includes restoring anything a previous on-state left behind. This is
    // the path a downgrade or an unequip arrives on: KSTPPolicySystem refreshes its cached
    // tier on the ripperdoc hooks and reaches here through Reapply(). ClearAll() below is
    // ungated for the same reason.
    if !KSTPGate.FactionAxisEnabled() || !sys.AxisAvailable() {
      sys.ReleaseAll();
      return;
    };
    // Proactive first, then reactive. SweepKnown() catches every NPC the spawn hook
    // recorded while the player was unarmed, which is nearly all of them, and
    // ReevaluateTracked() covers anything under the crosshair the spawn hook never saw.
    sys.SweepKnown();
    sys.ReevaluateTracked();
  }

  // Restore every entity this system has touched. Ungated on purpose: this is the
  // teardown path, and a teardown that refuses to run because the feature is already off
  // would strand modifiers on live NPCs forever. Must be called on gate-off, on a
  // protocol change to one without faction filtering, on cyberware unequip or downgrade
  // below KSTP_FactionAxisMinTier(), and at session end.
  //
  // Idempotent and cheap when nothing is tracked, so a caller that cannot tell whether
  // anything was ever applied should call it anyway.
  public final static func ClearAll(gi: GameInstance) -> Void {
    let sys: ref<KSTPFactionSystem> = KSTPFactionSystem.Get(gi);
    if !IsDefined(sys) {
      return;
    };
    sys.ReleaseAll();
  }
}

// -----------------------------------------------------------------------------
// The state holder.
//
// KSTPFaction's contract surface is static, but "restore what you mutate" needs a
// durable home for the touched set. A ScriptableSystem provides persistent fields, an
// OnDetach for session end, and an OnRestored for the reload case.
// -----------------------------------------------------------------------------

public class KSTPFactionSystem extends ScriptableSystem {

  // Entities currently carrying route-A lock-time inflation.
  private persistent let m_statSuppressed: array<EntityID>;

  // Every route-A modifier handle handed to StatsSystem, plus the entity each one went
  // on to, index-parallel. Release uses RemoveModifier against these handles and takes
  // back exactly what was applied. RemoveAllModifiers (orphans.script:16955) strips every
  // non-saved modifier on the stat regardless of origin, which would delete another mod's
  // or a quest effector's lock-time modifier off the same NPC.
  //
  // Not persistent: a ref<gameStatModifierData> is not serializable, and it does not need
  // to be. Non-saved AddModifier modifiers (orphans.script:16943, against AddSavedModifier
  // at :16947) do not survive a load either, so after a reload nothing remains on the NPC
  // for a stale handle to point at. Same reasoning as the OnRestored comment below.
  // KSTPBodyPartState.m_applied tracks the weapon side the same way.
  private let m_statMods: array<ref<gameStatModifierData>>;
  private let m_statModOwners: array<EntityID>;

  // Entities currently on the player's route-B look-at ignore list.
  private persistent let m_ignoreSuppressed: array<EntityID>;

  // The component-class set the current route-A modifier batch was built from, indexed
  // by KSTPTargetClass ordinal. An active protocol that wants a different set tears the
  // whole batch down and rebuilds it rather than patching per entity, which keeps a
  // mid-session protocol edit from leaving half-configured NPCs behind.
  private persistent let m_appliedClasses: array<Bool>;

  private let m_weaponBlackboard: ref<IBlackboard>;
  private let m_smartGunListener: ref<CallbackHandle>;

  // Cheap change detection for the blackboard tick. SmartGunParams is rewritten every
  // frame while a smart weapon is up, so the bookkeeping pass runs only when the tracked
  // ID set changes, plus a slow heartbeat so a pure attitude flip is still noticed.
  private let m_lastLockSet: array<EntityID>;
  private let m_heartbeat: Int32;

  // Diagnostic only. The spawn hook is the proactive half of enforcement: without it every
  // suppression decision falls to the delayed blackboard listener, which can lose the race
  // against a lock that is already forming. The Codeware call surface used by
  // HookSpawnCallback (n"Entity/Attach", EntityTarget.Type, EntityLifecycleEvent.GetEntity)
  // appears nowhere in the 2.31 dump, so this counter is what tells a bug report whether
  // the hook fires at all.
  private let m_spawnHits: Int32;

  // Every puppet the spawn hook has reported, whether or not it could be acted on at the
  // time. EvaluateOne requires policy.IsArmed(), meaning cyberware installed and a smart
  // weapon in hand, and an NPC rarely streams in during that moment, so nearly every spawn
  // arrives undecidable.
  //
  // Recording is therefore unconditional and cheap: one EntityID push, no classification,
  // no modifier. The decision is deferred to SweepKnown() on the next arm or protocol
  // change.
  private let m_known: array<EntityID>;


  public final static func Get(gi: GameInstance) -> ref<KSTPFactionSystem> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"KSTP.Enforcement.KSTPFactionSystem") as KSTPFactionSystem;
  }

  // Whether the installed coprocessor reaches the tier that enforces the faction axis
  // (Core/Policy.reds KSTP_FactionAxisMinTier). Distinct from KSTPGate.FactionAxisEnabled(),
  // which records whether the mechanism works on this build at all: both must hold before
  // anything is suppressed, and either going false is a release rather than a bare return.
  //
  // False with no policy system, so a load order that leaves Core out suppresses nothing.
  public final func AxisAvailable() -> Bool {
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(this.GetGameInstance());
    return IsDefined(policy) && policy.FactionAxisAvailable();
  }

  private func OnDetach() -> Void {
    this.ReleaseAll();
    this.UnhookBlackboard();
  }

  // A load drops every non-saved stat modifier (this system uses AddModifier rather than
  // AddSavedModifier, orphans.script:16943 against :16947), so after a reload the world is
  // clean while the persistent ID ledger is not, and m_statMods, being non-persistent, is
  // already empty. ReleaseAll() issues no native calls here; it resets the ledger so the
  // session starts from an empty one instead of carrying stale IDs forward.
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
  // Spawn hook: Codeware path, with a vanilla fallback below.
  // ---------------------------------------------------------------------------

  // The Codeware CallbackSystem event name n"Entity/Attach", the EntityTarget.Type()
  // selector, the EntityLifecycleEvent payload type and its GetEntity() accessor are
  // Codeware-side symbols. They are absent from the 2.31 game dump, so they cannot be
  // checked against it. The @if guard degrades a missing Codeware to the fallback below.
  // A renamed Codeware symbol becomes a compile error for users who do have Codeware,
  // which is the risk this comment flags.
  @if(ModuleExists("Codeware"))
  private final func HookSpawnCallback() -> Void {
    GameInstance.GetCallbackSystem()
      .RegisterCallback(n"Entity/Attach", this, n"OnEntityAttached")
      .AddTarget(EntityTarget.Type(n"ScriptedPuppet"))
      .SetLifetime(CallbackLifetime.Session);
  }

  @if(!ModuleExists("Codeware"))
  private final func HookSpawnCallback() -> Void {
    // Nothing to do: without Codeware the spawn signal arrives through the
    // @wrapMethod(ScriptedPuppet) OnGameAttached hook at the bottom of this file.
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

  private final func HookBlackboard(gi: GameInstance) -> Void {
    if IsDefined(this.m_weaponBlackboard) {
      return;
    };
    this.m_weaponBlackboard = GameInstance.GetBlackboardSystem(gi).Get(GetAllBlackboardDefs().UI_ActiveWeaponData);
    if !IsDefined(this.m_weaponBlackboard) {
      return;
    };
    this.m_smartGunListener = this.m_weaponBlackboard.RegisterDelayedListenerVariant(GetAllBlackboardDefs().UI_ActiveWeaponData.SmartGunParams, this, n"OnSmartGunParams");
  }

  private final func UnhookBlackboard() -> Void {
    if IsDefined(this.m_weaponBlackboard) && IsDefined(this.m_smartGunListener) {
      this.m_weaponBlackboard.UnregisterDelayedListener(GetAllBlackboardDefs().UI_ActiveWeaponData.SmartGunParams, this.m_smartGunListener);
    };
    this.m_smartGunListener = null;
    this.m_weaponBlackboard = null;
  }

  protected cb func OnSmartGunParams(value: Variant) -> Bool {
    if !KSTPGate.FactionAxisEnabled() {
      // Gate off means "be in the off state". This listener is the per-frame driver, so a
      // gate flip mid-session has to release any batch still applied right here; a bare
      // return would strand it forever. ReleaseAll() early-outs on an empty ledger, so the
      // steady-state cost of a false gate is one Mod Settings bool read plus a handful of
      // ArraySize() checks per frame.
      this.ReleaseAll();
      return false;
    };
    // The tier half of the same rule. Read once here and reused for the per-candidate pass
    // below, because KSTPPolicySystem.Get() is a container lookup and this runs every frame
    // a smart weapon is up. A player who sells or downgrades the coprocessor mid-fight lands
    // on this branch, and a bare return would strand the applied batch exactly as it would
    // above.
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
    // Decide every candidate the weapon is currently showing, ahead of the throttle below
    // and ahead of the bookkeeping passes.
    //
    // params.targets carries entries at Visible and Targetable as well as Locked
    // (gamesmartGunTargetState, orphans.script:8702), so an entity appears here while its
    // lock is still forming. A time-to-lock modifier prevents a lock; it cannot undo one
    // that has completed, so the decision has to land while the entity is still short of
    // Locked. ReevaluateTracked runs behind the heartbeat throttle below, so leaving the
    // decision to it would let a lock complete first at close range.
    //
    // This set is also the one the weapon has already range-filtered, a better definition
    // of "who matters" than every NPC in the district, and cheaper, since it skips the
    // pedestrians nobody will aim at.
    if policy.IsArmed() {
      let protocol: ref<KSTPProtocol> = policy.GetActive();
      if IsDefined(protocol) && protocol.factionFilterEnabled {
        let cand: ref<GameObject>;
        i = 0;
        while i < ArraySize(current) {
          // Remember it either way, so a later sweep covers entities the spawn hook never
          // saw: NPCs already in the world at load, or streamed in without a callback.
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
    // SmartGunParams is a per-frame write. The full bookkeeping pass runs only when the
    // tracked set moved, or roughly twice a second so a live attitude change is picked up.
    // The per-candidate decision above sits outside this throttle.
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

  public final func ReevaluateTracked() -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(gi);
    if !IsDefined(policy) {
      this.ReleaseAll();
      return;
    };
    let protocol: ref<KSTPProtocol> = policy.GetActive();
    // No protocol, no faction axis on it, an installed tier below KSTP_FactionAxisMinTier(),
    // or no smart weapon in hand: the correct state is "nothing suppressed". Suppressing
    // while unarmed would keep route A's allied-NPC collateral running while the player is
    // not even holding the gun, and suppressing below the tier would enforce an axis the
    // player has not bought.
    if !IsDefined(protocol) || !protocol.factionFilterEnabled || !policy.FactionAxisAvailable() || !policy.IsArmed() {
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
    i = 0;
    while i < ArraySize(live) {
      if !ArrayContains(tracked, live[i]) {
        obj = GameInstance.FindEntityByID(gi, live[i]) as GameObject;
        if IsDefined(obj) {
          this.Decide(obj, protocol);
        };
      };
      i += 1;
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

  // Re-decide every NPC the spawn hook has recorded, and drop the ones that streamed out.
  //
  // This is the proactive half of enforcement: it puts a verdict in place before a lock
  // can form. It runs on arm and protocol changes only, never per frame, so the cost is
  // one pass over a few hundred EntityIDs at the moment the player draws a smart weapon.
  // EvaluateOne re-checks the gate, the tier and IsArmed itself, so a sweep fired at a bad
  // moment is a no-op rather than an error.
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
    // Logged at Info rather than Debug: "is enforcement running" has to be answerable from
    // the log, because on-screen state is ambiguous. A smart weapon sits at Locking from
    // the hip whether or not anything is suppressing the target.
    //
    // The counts are split by route so the line names the mechanism holding targets down.
    // statMod is route A (SmartGunTimeToLock* inflation; the target still brackets and
    // sits at Locking), ignore is route B (AddIgnoredLookAtEntity). With
    // KSTPGate.IgnoreListWorks() off, which is how the mod ships, a healthy line reads
    // statMod=N ignore=0.
    KSTPLog.Debug(s"sweep: \(ArraySize(live)) live NPC(s), \(dropped) streamed out, suppression \(before) -> statMod=\(ArraySize(this.m_statSuppressed)) ignore=\(ArraySize(this.m_ignoreSuppressed))");
  }

  // Spawn-time path. Same decision, but it skips the enumeration entirely.
  public final func EvaluateOne(obj: ref<GameObject>) -> Void {
    // Public, so it re-checks the gate rather than trusting its callers. This is the
    // one entry point that can only ever add suppression, so with the gate off it must
    // not run at all; the release side lives on Reevaluate/ClearAll.
    if !KSTPGate.FactionAxisEnabled() {
      return;
    };
    let gi: GameInstance = this.GetGameInstance();
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(gi);
    // FactionAxisAvailable() for the same reason: this path only adds, so below
    // KSTP_FactionAxisMinTier() it returns rather than releasing. Anything a higher tier
    // left applied comes off through Reevaluate/ClearAll, which the loadout hooks in
    // Core/Policy.reds drive on every cyberware change.
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

  private final func Decide(obj: ref<GameObject>, protocol: ref<KSTPProtocol>) -> Void {
    if !IsDefined(obj) {
      return;
    };
    let id: EntityID = obj.GetEntityID();
    if !EntityID.IsDefined(id) {
      return;
    };
    // Never touch the player. Route A would slow the player's own lockability for
    // anyone shooting at them; route B would delete them from their own look-at set.
    if IsDefined(obj as PlayerPuppet) {
      return;
    };
    if obj.IsDead() {
      this.Release(id);
      return;
    };
    let classification: ref<KSTPClassification> = KSTPClassifier.Classify(obj);
    if !IsDefined(classification) || KSTPClassifier.Permits(protocol, classification) {
      this.Release(id);
      return;
    };
    this.Suppress(obj);
  }

  // ---------------------------------------------------------------------------
  // Apply / restore
  // ---------------------------------------------------------------------------

  private final func Suppress(obj: ref<GameObject>) -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let id: EntityID = obj.GetEntityID();

    if KSTPGate.IgnoreListWorks() {
      // Route B: observer-scoped, one native call, exact undo. The smart gun does not
      // consult the look-at ignore list, so this path suppresses nothing on 2.31; the gate
      // ships off and the code is kept as the documented alternative.
      if ArrayContains(this.m_ignoreSuppressed, id) {
        return;
      };
      let player: ref<PlayerPuppet> = GetPlayer(gi);
      if !IsDefined(player) {
        return;
      };
      // Route A may have been the active route a moment ago; clearing it here keeps the
      // same entity from being held down through both mechanisms at once.
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
    let i: Int32 = 0;
    while i < KSTPTargetClassCount() {
      if i < ArraySize(classes) && classes[i] {
        statType = KSTPStats.TimeToLockStatFor(IntEnum<KSTPTargetClass>(i));
        if NotEquals(statType, gamedataStatType.Invalid) {
          // The stat is itself a multiplier whose vanilla value is 1.0, so a Multiplier
          // modifier lands the effective time-to-lock at SuppressionMultiplier() x vanilla.
          // An Additive modifier would add a raw offset instead.
          data = RPGManager.CreateStatModifier(statType, gameStatModifierType.Multiplier, KSTPStats.SuppressionMultiplier());
          if stats.AddModifier(objID, data) {
            // Keep the exact handle so release can be surgical. Tracked only once the
            // game has accepted it, so release never targets a modifier never applied.
            ArrayPush(this.m_statMods, data);
            ArrayPush(this.m_statModOwners, id);
          };
        };
      };
      i += 1;
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

  // Take back exactly the modifiers applied to `id`, and nothing else.
  //
  // RemoveModifier (orphans.script:16949), never RemoveAllModifiers (:16955): the latter
  // strips every non-saved modifier on the named stat regardless of who added it, so
  // sweeping the seven SmartGunTimeToLock* stats of a world NPC would silently delete a
  // lock-time modifier another mod or a quest effector had applied to the same NPC. Rule
  // 4 cuts both ways: restore what was mutated, and only what was mutated.
  //
  // `removeNative` false is the entity-is-gone path. The stats object died with the
  // entity, so there is nothing to call into and only the handles are dropped.
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
    // Prune first and unconditionally: a handle whose ledger entry went missing still
    // has to come off the NPC, so this must not hang off the ArrayContains check.
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
    // If the player object is gone the ignore list went with the session; drop the entry
    // either way so a failed lookup cannot pin the ledger open forever.
    let ignored: array<EntityID> = this.m_ignoreSuppressed;
    ArrayRemove(ignored, id);
    this.m_ignoreSuppressed = ignored;
  }

  // True when nothing is applied and nothing is remembered, so ReleaseAll() has no work
  // to do. Kept to five ArraySize() calls because the gate-off path in OnSmartGunParams
  // runs this every frame a smart weapon is up.
  private final func IsIdle() -> Bool {
    return ArraySize(this.m_statSuppressed) == 0 && ArraySize(this.m_statMods) == 0 && ArraySize(this.m_ignoreSuppressed) == 0 && ArraySize(this.m_appliedClasses) == 0 && ArraySize(this.m_lastLockSet) == 0;
  }

  // Idempotent by construction: it releases what is tracked and then leaves the ledger
  // empty, so a second call, a call while the gate is off, or a call on a system that
  // never applied anything is a cheap no-op. Safe to call from any teardown path.
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
    // A modifier handle whose ledger entry went missing still has to come off the NPC it
    // was applied to. Duplicated owners cost one no-op pass each.
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
    // Each Clear* prunes its own entry, and the ledger stays authoritative either way.
    // Resetting everything explicitly keeps a partial failure above from leaving a
    // phantom entry behind.
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
  // Which component classes a denial has to cover
  // ---------------------------------------------------------------------------

  // Under STRICT the weapon-side track stat for a denied class is already zero, so the
  // gun cannot lock that class on anybody and only the classes the protocol still permits
  // have to be closed. Under PREFERRED the denied classes are slowed rather than switched
  // off, so a refused target could still be reached through one of them: cover all seven.
  private final static func WantedClasses(protocol: ref<KSTPProtocol>) -> array<Bool> {
    let out: array<Bool>;
    let preferred: Bool = Equals(protocol.lockPolicy, KSTPLockPolicy.Preferred);
    let i: Int32 = 0;
    while i < KSTPTargetClassCount() {
      ArrayPush(out, preferred || protocol.Allows(IntEnum<KSTPTargetClass>(i)));
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
      // Spelled out rather than a Bool inequality: the 2.31 dump declares no
      // OperatorNotEqual(Bool, Bool), so this avoids leaning on one.
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

// -----------------------------------------------------------------------------
// Degraded spawn hook for installs without Codeware.
//
// NPCPuppet.OnGameAttached calls super.OnGameAttached() (NPCPuppet.script:376), so
// wrapping the ScriptedPuppet override (scriptedPuppet.script:483) catches regular NPCs
// as well as anything else deriving from ScriptedPuppet. This costs one gated static
// call per puppet attach, which is why KSTPFaction.OnNPCSpawned checks the gate first.
// -----------------------------------------------------------------------------

@if(!ModuleExists("Codeware"))
@wrapMethod(ScriptedPuppet)
protected cb func OnGameAttached() -> Bool {
  let result: Bool = wrappedMethod();
  KSTPFaction.OnNPCSpawned(this);
  return result;
}
