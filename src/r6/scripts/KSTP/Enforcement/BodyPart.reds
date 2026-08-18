// Kiroshi Smart Targeting Protocol: body-part enforcement.
//
// Provides KSTPBodyPart, the facade named in docs/ARCHITECTURE.md, over the
// KSTPBodyPartState ScriptableSystem; redscript has no static fields. Requires KSTP.Core.
//
// Acquisition is native end to end and exposes no per-candidate veto. The lever is the
// weapon-side SmartGun* stat block the handler reads (orphans.script:2775-2791), written
// through StatsSystem.AddModifier / RemoveModifier (orphans.script:16943 / 16949). STRICT
// zeroes SmartGunTrack<Class>Components; PREFERRED inflates
// SmartGunTimeToLock<Class>ComponentMultiplier on denied classes instead. Denying every class
// does not exclude a target: the handler falls back to a raw head slot (weapon.script:1526).
// Vehicle is the exception and is hard-denied under either policy, because lock-time inflation
// was measured to have no effect on a car. See ADR 0006 and ADR 0013.
//
// The weapon's stats object is rebuilt on every draw, so modifiers are re-applied on equip and
// removed on unequip, and each one is tracked so removal is exact (CONTRACT hard rule 4).

module KSTP.Enforcement

import KSTP.Core.*

// Watches AttachmentSlots.WeaponRight so enforcement follows weapon draws. Registered as an
// AttachmentSlotsScriptCallback rather than by patching a method, the approach vanilla takes in
// ApplyStatGroupEffector (core/gameplay/effectors/applyStatGroupEffector.script), the effector
// behind Items.KiroshiOpticsFragment1's SmartGunTrackLegComponents modifier; it costs no
// @wrapMethod and so collides with nothing (ADR 0002). The native listener filters by slotID,
// so the handlers do not re-check it. WeaponRight only: the player's ranged weapons are always
// right-hand, and WeaponLeft holds cyberware and dual-wield melee, neither of which can be a
// smart gun.
public class KSTPBodyPartSlotCallback extends AttachmentSlotsScriptCallback {

  public let system: wref<KSTPBodyPartState>;

  public func OnItemEquipped(slot: TweakDBID, item: ItemID) -> Void {
    if IsDefined(this.system) {
      this.system.OnWeaponSlotChanged(true);
    };
  }

  public func OnItemUnequipped(slot: TweakDBID, item: ItemID) -> Void {
    if IsDefined(this.system) {
      this.system.OnWeaponSlotChanged(false);
    };
  }
}

// Mod-global body-part state: the modifiers applied, the stats object they went to, and the
// protocol last requested. Owns the weapon-slot listener and re-applies the protocol across
// draw, holster, load and world transition.
public class KSTPBodyPartState extends ScriptableSystem {

  // Every modifier handed to StatsSystem, in application order.
  private let m_applied: array<ref<gameStatModifierData>>;

  // The stats object those modifiers went to. Held separately from the weapon because on
  // unequip the weapon can already be out of the slot when the callback arrives, and removal
  // still has to reach the right object.
  private let m_target: StatsObjectID;
  private let m_hasTarget: Bool;

  // Retained across holster and draw so the slot callback can re-apply without consulting
  // KSTPPolicySystem.
  private let m_protocol: ref<KSTPProtocol>;

  private let m_slotListener: ref<AttachmentSlotsScriptListener>;
  private let m_slotCallback: ref<KSTPBodyPartSlotCallback>;

  // Selects which stats object the modifiers are written to; see ResolveWeaponStatsObject.
  // Diagnostic alternative only. false is the path the smart-gun handler reads.
  private let m_useEntityStatsObject: Bool;

  private let m_debug: Bool;

  public final static func Get(gi: GameInstance) -> ref<KSTPBodyPartState> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"KSTP.Enforcement.KSTPBodyPartState") as KSTPBodyPartState;
  }

  // The protocol survives a load or world transition; the weapon and its stats object do not.
  private final func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    this.EnsureSlotListener();
    this.ApplyProtocol(this.m_protocol);
  }

  private final func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    this.Suspend();
  }

  private func OnDetach() -> Void {
    this.Teardown();
  }

  // Drops everything bound to the current player and weapon instance. The protocol is kept, so
  // enforcement resumes on the next attach.
  public final func Suspend() -> Void {
    this.RemoveApplied();
    this.DropSlotListener();
  }

  // Full stop. Leaves no stat modifier behind (CONTRACT hard rule 4).
  public final func Teardown() -> Void {
    this.Suspend();
    this.m_protocol = null;
  }

  // --- Slot listener ---

  public final func EnsureSlotListener() -> Void {
    if IsDefined(this.m_slotListener) {
      return;
    };
    let player: ref<PlayerPuppet> = GetPlayer(this.GetGameInstance());
    if !IsDefined(player) {
      return;
    };
    this.m_slotCallback = new KSTPBodyPartSlotCallback();
    this.m_slotCallback.slotID = t"AttachmentSlots.WeaponRight";
    this.m_slotCallback.system = this;
    this.m_slotListener = GameInstance.GetTransactionSystem(this.GetGameInstance()).RegisterAttachmentSlotListener(player, this.m_slotCallback);
  }

  private final func DropSlotListener() -> Void {
    if !IsDefined(this.m_slotListener) {
      return;
    };
    let player: ref<PlayerPuppet> = GetPlayer(this.GetGameInstance());
    if IsDefined(player) {
      GameInstance.GetTransactionSystem(this.GetGameInstance()).UnregisterAttachmentSlotListener(player, this.m_slotListener);
    };
    this.m_slotListener = null;
    this.m_slotCallback = null;
  }

  // A draw brings a new weapon instance and a new stats object. A holster drops the modifiers
  // and keeps the protocol, so the next draw re-arms without the caller acting.
  public final func OnWeaponSlotChanged(equipped: Bool) -> Void {
    if equipped {
      this.ApplyProtocol(this.m_protocol);
    } else {
      this.RemoveApplied();
    };
  }

  // --- Application ---

  // Writes p to the held smart weapon. Clears whatever is live first, from whatever object it
  // went on to, so repeated calls cannot stack. Safe with nothing in hand: p is remembered and
  // the slot callback applies it on the next draw.
  public final func ApplyProtocol(p: ref<KSTPProtocol>) -> Void {
    this.RemoveApplied();
    this.m_protocol = p;
    if !IsDefined(p) {
      return;
    };

    this.EnsureSlotListener();

    let gi: GameInstance = this.GetGameInstance();
    let weapon: wref<WeaponObject> = KSTPBodyPart.GetHeldSmartWeapon(gi);
    if !IsDefined(weapon) {
      this.Log("no smart weapon held, deferring");
      return;
    };

    let target: StatsObjectID;
    if !KSTPBodyPart.ResolveWeaponStatsObject(weapon, this.m_useEntityStatsObject, target) {
      this.Log("could not resolve a stats object for the held weapon");
      return;
    };
    this.m_target = target;
    this.m_hasTarget = true;

    let stats: ref<StatsSystem> = GameInstance.GetStatsSystem(gi);
    let strict: Bool = Equals(p.lockPolicy, KSTPLockPolicy.Strict);
    let classes: array<KSTPTargetClass> = KSTPBodyPart.AllClasses();
    let cls: KSTPTargetClass;
    let denied: String = "";
    let i: Int32 = 0;
    while i < ArraySize(classes) {
      cls = classes[i];
      if !p.Allows(cls) {
        // Vehicle is the one class hard-denied under either policy. Measured on 2.31: with the
        // vehicle time-to-lock multiplier inflated 1000x, a car still takes a full lock at
        // normal speed, while identical inflation holds an NPC at Locking indefinitely.
        // PREFERRED read back VEHICLE=4.000000 and locked cars; STRICT read back 0.000000 and
        // did not. SOFT is no refusal at all here. See ADR 0013.
        if strict || Equals(cls, KSTPTargetClass.Vehicle) {
          this.DenyHard(stats, cls);
          denied += KSTPStats.ClassLabel(cls) + "=HARD ";
        } else {
          this.DenySoft(stats, cls);
          denied += KSTPStats.ClassLabel(cls) + "=SOFT ";
        };
      };
      i += 1;
    };

    this.ApplyMultiEntityADS(stats, p);

    this.Log(s"applied \(ArraySize(this.m_applied)) modifier(s) for protocol \(p.displayName)");

    // Readback is ground truth rather than intent: these are the numbers the native handler
    // consults on its next tick. A class reading 0.00 cannot be acquired; a non-zero one can,
    // however the menu is set.
    //
    // It is the stat total from every source, not this mod's contribution. Other mods write the
    // same stats on the same weapon (docs/COMPATIBILITY.md), so a class can read a value KSTP
    // never wrote, and one this mod granted reads as its own 2 plus theirs. A reading that is not
    // 0 or a multiple of 2 has another writer in it by definition. Diagnosing from these numbers
    // without allowing for that produced two false defect reports.
    if KSTPLog.DebugEnabled() {
      let readback: String = "";
      let st: gamedataStatType;
      let j: Int32 = 0;
      while j < ArraySize(classes) {
        st = KSTPStats.TrackStatFor(classes[j]);
        if NotEquals(st, gamedataStatType.Invalid) {
          readback += KSTPStats.ClassLabel(classes[j]) + "=" + ToString(stats.GetStatValue(this.m_target, st)) + " ";
        };
        j += 1;
      };
      let policyName: String = "PREFERRED(soft: class still acquired)";
      if strict {
        policyName = "STRICT(hard: class removed)";
      };
      if StrLen(denied) == 0 {
        denied = "(none) ";
      };
      KSTPLog.Debug(s"bodypart: protocol=\(p.displayName) policy=\(policyName) | denied: \(denied)| weapon totals, all sources: \(readback)");
    };

    // Gate off: the stats are treated as latched when the weapon came up, so force a re-latch.
    if !KSTPBodyPart.LiveRereadConfirmed() {
      this.CycleSmartGunHandler(weapon);
    };
  }

  // STRICT. Multiplier 0 zeroes the stat whatever its base and whatever other sources
  // contributed. SmartGunTrack*Components is a component count (vanilla base weapon: Chest 3,
  // Leg 2, Mechanical 1) that cyberware such as KiroshiOpticsFragment1 adds to, so an additive
  // modifier would have to guess the total. Multiplier is a straight multiply; the 1+x blend is
  // the separate AdditiveMultiplier member of gameStatModifierType (orphans.script:511-517).
  // Vanilla hard-zeroes a stat this way at vendor.script:512 and upperBodyTransitions.script:1720.
  private final func DenyHard(stats: ref<StatsSystem>, cls: KSTPTargetClass) -> Void {
    this.AddMod(stats, KSTPStats.TrackStatFor(cls), gameStatModifierType.Multiplier, 0.00);
  }

  // PREFERRED. Track stats are left exactly as the weapon and the player's cyberware set them;
  // only the denied class's time-to-lock is inflated, so a permitted component always wins the
  // race for the same target. Multiplying preserves the ordering between classes that the
  // weapon, mods and perks established.
  private final func DenySoft(stats: ref<StatsSystem>, cls: KSTPTargetClass) -> Void {
    let stat: gamedataStatType = KSTPStats.TimeToLockStatFor(cls);
    if Equals(stat, gamedataStatType.Invalid) {
      return;
    };
    let k: Float = KSTPStats.SuppressionMultiplier();
    let base: Float = stats.GetStatValue(this.m_target, stat);
    if base > 0.001 {
      this.AddMod(stats, stat, gameStatModifierType.Multiplier, k);
    } else {
      // A neutral-zero base swallows any Multiplier; additive still lands.
      this.AddMod(stats, stat, gameStatModifierType.Additive, k);
    };
  }

  // SmartGunTrackMultipleEntitiesInADS (orphans.script:2789) is named as if it governs
  // multi-target tracking while aiming, but nothing in the 2.31 script dump reads it, so its
  // effect is unproven. multiEntityADS below 0 leaves vanilla alone and is the shipping default.
  private final func ApplyMultiEntityADS(stats: ref<StatsSystem>, p: ref<KSTPProtocol>) -> Void {
    if p.multiEntityADS < 0 {
      return;
    };
    let stat: gamedataStatType = gamedataStatType.SmartGunTrackMultipleEntitiesInADS;
    let want: Float = Cast<Float>(p.multiEntityADS);
    if want <= 0.00 {
      this.AddMod(stats, stat, gameStatModifierType.Multiplier, 0.00);
      return;
    };
    // Additive delta against the live value, as ripperdoc.script:517 zeroes HumanityAllocated:
    // the only way to land on an absolute target with a reversible modifier.
    let current: Float = stats.GetStatValue(this.m_target, stat);
    let delta: Float = want - current;
    if AbsF(delta) > 0.001 {
      this.AddMod(stats, stat, gameStatModifierType.Additive, delta);
    };
  }

  private final func AddMod(stats: ref<StatsSystem>, stat: gamedataStatType, modType: gameStatModifierType, value: Float) -> Void {
    if Equals(stat, gamedataStatType.Invalid) {
      return;
    };
    let data: ref<gameStatModifierData> = RPGManager.CreateStatModifier(stat, modType, value);
    if stats.AddModifier(this.m_target, data) {
      // Tracked only once the game has accepted it, so removal never targets a modifier that
      // was never applied.
      ArrayPush(this.m_applied, data);
    } else {
      let statName: String = EnumValueToString("gamedataStatType", Cast<Int64>(EnumInt(stat)));
      this.Log(s"AddModifier refused \(statName)");
    };
  }

  // --- Removal ---

  // Removes every tracked modifier and forgets the target. Removing from a stats object whose
  // entity is already gone is a no-op, which is the required behaviour on the unequip path.
  public final func RemoveApplied() -> Void {
    if ArraySize(this.m_applied) == 0 {
      this.ForgetTarget();
      return;
    };
    let stats: ref<StatsSystem> = GameInstance.GetStatsSystem(this.GetGameInstance());
    let i: Int32 = 0;
    while i < ArraySize(this.m_applied) {
      stats.RemoveModifier(this.m_target, this.m_applied[i]);
      i += 1;
    };
    this.Log(s"removed \(ArraySize(this.m_applied)) modifier(s)");
    ArrayClear(this.m_applied);
    this.ForgetTarget();
  }

  private final func ForgetTarget() -> Void {
    let blank: StatsObjectID;
    this.m_target = blank;
    this.m_hasTarget = false;
  }

  // --- Re-latch ---

  // Soft re-latch. EnableSmartGunHandlerEvent (orphans.script:61871) is the event vehicle combat
  // uses to switch the weapon's native smart-gun handler on and off
  // (vehicleTransition.script:2424-2435); bouncing it drives the handler to re-read the weapon's
  // stat block. The two events must land on different frames for the native side to see two
  // distinct transitions. Skipped while mounted: in a vehicle vanilla drives `enable` from the
  // aim button, and forcing it true would leave the handler on outside ADS until the next aim
  // change.
  public final func CycleSmartGunHandler(weapon: wref<WeaponObject>) -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(gi);
    if !IsDefined(weapon) || !IsDefined(player) {
      return;
    };
    if VehicleComponent.IsMountedToVehicle(gi, player) {
      return;
    };
    let off: ref<EnableSmartGunHandlerEvent> = new EnableSmartGunHandlerEvent();
    off.owner = player;
    off.enable = false;
    weapon.QueueEvent(off);

    let on: ref<EnableSmartGunHandlerEvent> = new EnableSmartGunHandlerEvent();
    on.owner = player;
    on.enable = true;
    GameInstance.GetDelaySystem(gi).DelayEventNextFrame(weapon, on);
  }

  // Hard re-latch. Re-equips the weapon (EquipmentManipulationAction.ReequipWeapon,
  // orphans.script:11218, the action WaitForEquipEvents uses at
  // upperBodyTransitions.script:1948), tearing the weapon entity down and rebuilding it along
  // with anything latched at draw time. Costs a visible draw animation, so it is never
  // automatic; only KSTPBodyPart.ForceReequip() calls it. No re-entrancy guard is needed: the
  // unequip/equip pair arrives through the slot callback, and re-applying the protocol against
  // the rebuilt weapon is the intended outcome.
  public final func RequestReequip() -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(gi);
    let equipment: ref<EquipmentSystem> = GameInstance.GetScriptableSystemsContainer(gi).Get(n"EquipmentSystem") as EquipmentSystem;
    if !IsDefined(player) || !IsDefined(equipment) {
      return;
    };
    let request: ref<EquipmentSystemWeaponManipulationRequest> = new EquipmentSystemWeaponManipulationRequest();
    request.owner = player;
    request.requestType = EquipmentManipulationAction.ReequipWeapon;
    equipment.QueueRequest(request);
  }

  // --- Introspection ---
  //
  // Queries rather than log calls, so this module stays dependency-free.

  public final func GetAppliedCount() -> Int32 {
    return ArraySize(this.m_applied);
  }

  public final func HasTarget() -> Bool {
    return this.m_hasTarget;
  }

  public final func GetProtocol() -> ref<KSTPProtocol> {
    return this.m_protocol;
  }

  // Only ever called right after RemoveApplied(), by KSTPBodyPart.Clear().
  public final func SetProtocolCleared() -> Void {
    this.m_protocol = null;
  }

  public final func SetDebug(v: Bool) -> Void {
    this.m_debug = v;
  }

  public final func UsesEntityStatsObject() -> Bool {
    return this.m_useEntityStatsObject;
  }

  // Re-applies in place, so the caller need not clear first.
  public final func SetUseEntityStatsObject(v: Bool) -> Void {
    if Equals(this.m_useEntityStatsObject, v) {
      return;
    };
    let p: ref<KSTPProtocol> = this.m_protocol;
    this.RemoveApplied();
    this.m_useEntityStatsObject = v;
    this.ApplyProtocol(p);
  }

  public final func Describe() -> String {
    let name: String = IsDefined(this.m_protocol) ? this.m_protocol.displayName : "none";
    let mode: String = this.m_useEntityStatsObject ? "entity" : "itemdata";
    return s"KSTPBodyPart[protocol=\(name) mods=\(ArraySize(this.m_applied)) target=\(this.m_hasTarget) via=\(mode)]";
  }

  private final func Log(msg: String) -> Void {
    if this.m_debug {
      FTLog(s"[KSTP.BodyPart] \(msg)");
    };
  }
}

// Static facade over KSTPBodyPartState: the interface in docs/ARCHITECTURE.md. Every entry point
// is a no-op while the system is unavailable.
public class KSTPBodyPart {

  // Translates a protocol's body-part axis into stat modifiers on the held smart weapon. Clears
  // first, so repeated calls cannot stack. Safe with no weapon in hand: the protocol is
  // remembered and applied on the next draw.
  public final static func Apply(gi: GameInstance, p: ref<KSTPProtocol>) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.ApplyProtocol(p);
  }

  // Full stop. Removes every applied modifier and forgets the protocol, so a later weapon swap
  // does not silently re-arm. Use Reapply() to refresh instead.
  public final static func Clear(gi: GameInstance) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.RemoveApplied();
    state.SetProtocolCleared();
  }

  // Re-runs the last-applied protocol against whatever is in hand now.
  public final static func Reapply(gi: GameInstance) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.ApplyProtocol(state.GetProtocol());
  }

  // Forces the native smart-gun handler to pick the current stats up again. Required only where
  // KSTPGate.LiveStatReread() is false, in which case the stats count as latched when the weapon
  // comes up and a caller changing the protocol mid-draw must call this afterwards. ApplyProtocol
  // already runs this path automatically whenever that gate is off.
  public final static func ForceRefresh(gi: GameInstance) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.CycleSmartGunHandler(KSTPBodyPart.GetHeldSmartWeapon(gi));
  }

  // Re-equips the weapon so everything latched at draw time is rebuilt. Costs a visible draw
  // animation, so it serves diagnostics and a manual "reapply now" action, not routine protocol
  // changes.
  public final static func ForceReequip(gi: GameInstance) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.RequestReequip();
  }

  // The seven classes in KSTPTargetClass ordinal order. Redscript has no enum reflection; this
  // list and KSTPTargetClassCount() are maintained together.
  public final static func AllClasses() -> array<KSTPTargetClass> = [
    KSTPTargetClass.Head,
    KSTPTargetClass.Chest,
    KSTPTargetClass.Leg,
    KSTPTargetClass.WeakSpot,
    KSTPTargetClass.Mechanical,
    KSTPTargetClass.Breach,
    KSTPTargetClass.Vehicle
  ]

  // The held weapon, and null unless it is a smart weapon: the SmartGun* stats mean nothing on
  // anything else. Right hand then left, matching ScriptedPuppet.GetActiveWeapon
  // (scriptedPuppet.script:1787).
  public final static func GetHeldSmartWeapon(gi: GameInstance) -> wref<WeaponObject> {
    let player: ref<PlayerPuppet> = GetPlayer(gi);
    if !IsDefined(player) {
      return null;
    };
    let weapon: wref<WeaponObject> = ScriptedPuppet.GetActiveWeapon(player);
    if !IsDefined(weapon) {
      return null;
    };
    let record: ref<WeaponItem_Record> = weapon.GetWeaponRecord();
    if !IsDefined(record) || !IsDefined(record.Evolution()) {
      return null;
    };
    if NotEquals(record.Evolution().Type(), gamedataWeaponEvolution.Smart) {
      return null;
    };
    return weapon;
  }

  // Resolves the stats object a weapon's SmartGun* stats live on, and reports whether it is
  // valid. Vanilla resolves applicationTarget "Weapon", the path Items.KiroshiOpticsFragment1
  // takes to put SmartGunTrackLegComponents on the held gun, as
  // weapon.GetItemData().GetStatsObjectID() (effector.script:33); that is the authority and the
  // default. `useEntity` selects the Cast<StatsObjectID>(weapon.GetEntityID()) form the combat
  // code uses for other weapon stats (aiActionHelper.script:555), which is also the fallback
  // when itemData yields no valid object.
  public final static func ResolveWeaponStatsObject(weapon: wref<WeaponObject>, useEntity: Bool, out target: StatsObjectID) -> Bool {
    if !IsDefined(weapon) {
      return false;
    };
    if !useEntity {
      let data: wref<gameItemData> = weapon.GetItemData();
      if IsDefined(data) {
        target = data.GetStatsObjectID();
        if StatsObjectID.IsDefined(target) {
          return true;
        };
      };
    };
    target = Cast<StatsObjectID>(weapon.GetEntityID());
    return StatsObjectID.IsDefined(target);
  }

  // Isolates this file's one cross-module dependency. False means take the conservative route
  // and force a re-latch after every apply.
  public final static func LiveRereadConfirmed() -> Bool {
    return KSTPGate.LiveStatReread();
  }

  // --- Diagnostics ---

  public final static func IsApplied(gi: GameInstance) -> Bool {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    return IsDefined(state) && state.GetAppliedCount() > 0;
  }

  public final static func DescribeState(gi: GameInstance) -> String {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return "KSTPBodyPart[system unavailable]";
    };
    return state.Describe();
  }

  public final static func SetDebug(gi: GameInstance, v: Bool) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if IsDefined(state) {
      state.SetDebug(v);
    };
  }

  // Switches which stats object is targeted and re-applies in place.
  public final static func SetUseEntityStatsObject(gi: GameInstance, v: Bool) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if IsDefined(state) {
      state.SetUseEntityStatsObject(v);
    };
  }
}
