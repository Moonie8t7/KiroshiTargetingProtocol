// Kiroshi Smart Targeting Protocol: body-part enforcement.
//
// Smart-gun candidate acquisition is native end to end and exposes no per-candidate
// veto to redscript. The available lever is the weapon-side SmartGun* stat block the
// native handler reads (orphans.script:2775-2791), driven through
// StatsSystem.AddModifier / RemoveModifier (orphans.script:16943 / 16949).
//
// One lever per policy:
//
//   STRICT      SmartGunTrack<Class>Components forced to 0, so the class is not
//               tracked at all.
//   PREFERRED   track stats untouched; SmartGunTimeToLock<Class>ComponentMultiplier
//               inflated on denied classes so they lose every lock race to the
//               permitted ones.
//
// Denying every class does not stop targeting: with no tracked components the handler
// falls back to a raw head slot (weapon.script:1526).
//
// The modifiers live on the weapon's stats object, which is re-created whenever the
// weapon is drawn, so everything is re-applied on equip and removed on unequip. Every
// modifier added is tracked so it can be removed exactly; nothing here relies on the
// game cleaning up afterwards.
//
// Redscript has no static fields, so all state lives on KSTPBodyPartState (a
// ScriptableSystem, the corpus idiom for mod-global state) and KSTPBodyPart is a
// thin static facade over it, matching the interface in docs/ARCHITECTURE.md.

module KSTP.Enforcement

import KSTP.Core.*

// ---------------------------------------------------------------------------
// Weapon slot watcher
//
// Vanilla model: ApplyStatGroupEffector (core/gameplay/effectors/applyStatGroupEffector.script),
// the effector behind Items.KiroshiOpticsFragment1's SmartGunTrackLegComponents modifier,
// reacts to weapon changes by registering an AttachmentSlotsScriptCallback on the owner
// rather than by patching any method. The same approach is used here, which costs no
// @wrapMethod and so collides with nothing.
//
// The native listener filters by `slotID`, which is why the vanilla callback does not
// re-check the slot in its handlers. As in vanilla, only WeaponRight is watched: the
// player's ranged weapons are always right-hand, and WeaponLeft holds cyberware and
// dual-wield melee, neither of which can be a smart gun.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

public class KSTPBodyPartState extends ScriptableSystem {

  // Every modifier handed to StatsSystem, in application order.
  private let m_applied: array<ref<gameStatModifierData>>;

  // The stats object those modifiers went to. Held separately from the weapon
  // because on unequip the weapon can already be out of the slot when the callback
  // arrives, and removal still has to reach the right object.
  private let m_target: StatsObjectID;
  private let m_hasTarget: Bool;

  // Last protocol handed to Apply(). Retained across holster/draw so the slot
  // callback can re-apply it without asking KSTPPolicySystem.
  private let m_protocol: ref<KSTPProtocol>;

  private let m_slotListener: ref<AttachmentSlotsScriptListener>;
  private let m_slotCallback: ref<KSTPBodyPartSlotCallback>;

  // Which stats object the modifiers are written to.
  // false = weapon.GetItemData().GetStatsObjectID(), the path vanilla uses for
  // applicationTarget "Weapon" (effector.script:33) and the one the smart-gun
  // handler reads. true = the entity-derived
  // Cast<StatsObjectID>(weapon.GetEntityID()) used for weapon combat stats
  // elsewhere (aiActionHelper.script:555), kept as a diagnostic alternative.
  private let m_useEntityStatsObject: Bool;

  private let m_debug: Bool;

  public final static func Get(gi: GameInstance) -> ref<KSTPBodyPartState> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"KSTP.Enforcement.KSTPBodyPartState") as KSTPBodyPartState;
  }

  private final func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    this.EnsureSlotListener();
    // Self-heal across a load or world transition: the protocol survived the
    // detach, the weapon and its stats object did not. No-op while unarmed.
    this.ApplyProtocol(this.m_protocol);
  }

  private final func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    // The modified stats object is about to go away, and the listener is bound to a
    // player entity that is going away with it. The protocol is kept: enforcement must
    // not silently stop because the world reloaded.
    this.Suspend();
  }

  private func OnDetach() -> Void {
    this.Teardown();
  }

  // Drops everything bound to the current player/weapon instance.
  public final func Suspend() -> Void {
    this.RemoveApplied();
    this.DropSlotListener();
  }

  // Full stop. Rule 4: the mod leaves no stat modifier behind on unload.
  public final func Teardown() -> Void {
    this.Suspend();
    this.m_protocol = null;
  }

  // -------------------------------------------------------------------------
  // Slot listener
  // -------------------------------------------------------------------------

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

  public final func OnWeaponSlotChanged(equipped: Bool) -> Void {
    if equipped {
      // New weapon instance, new stats object: re-run the protocol against it.
      this.ApplyProtocol(this.m_protocol);
    } else {
      // Holstered or swapped away. Drop the modifiers but keep the protocol so
      // the next draw re-arms without the caller having to notice.
      this.RemoveApplied();
    };
  }

  // -------------------------------------------------------------------------
  // Application
  // -------------------------------------------------------------------------

  public final func ApplyProtocol(p: ref<KSTPProtocol>) -> Void {
    // Never stack: whatever is live comes off first, from whatever object it
    // went on to, before anything new goes down.
    this.RemoveApplied();
    this.m_protocol = p;
    if !IsDefined(p) {
      return;
    };

    this.EnsureSlotListener();

    let gi: GameInstance = this.GetGameInstance();
    let weapon: wref<WeaponObject> = KSTPBodyPart.GetHeldSmartWeapon(gi);
    if !IsDefined(weapon) {
      // Nothing smart in hand. The protocol stays remembered; the slot callback
      // will apply it the moment one is drawn.
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
    let i: Int32 = 0;
    while i < ArraySize(classes) {
      cls = classes[i];
      if !p.Allows(cls) {
        if strict {
          this.DenyHard(stats, cls);
        } else {
          this.DenySoft(stats, cls);
        };
      };
      i += 1;
    };

    this.ApplyMultiEntityADS(stats, p);

    this.Log(s"applied \(ArraySize(this.m_applied)) modifier(s) for protocol \(p.displayName)");

    // The native handler re-reads these stats live, so a protocol change binds at
    // once. Where KSTPBodyPart.LiveRereadConfirmed() is false, the stats are treated
    // as latched when the weapon came up and a re-latch is forced. Gate off means do
    // the extra work, gate on means skip it.
    if !KSTPBodyPart.LiveRereadConfirmed() {
      this.CycleSmartGunHandler(weapon);
    };
  }

  // STRICT. Multiplier 0 zeroes the stat whatever its base and whatever other
  // sources contributed. SmartGunTrack*Components is a component count (vanilla
  // base weapon: Chest 3, Leg 2, Mechanical 1) and cyberware such as
  // KiroshiOpticsFragment1 adds to it, so an additive modifier would have to guess
  // the total. Multiplier is a straight multiply; the 1+x blend is the separate
  // AdditiveMultiplier member of gameStatModifierType (orphans.script:511-517).
  // Vanilla hard-zeroes a stat exactly this way at vendor.script:512 and
  // upperBodyTransitions.script:1720.
  private final func DenyHard(stats: ref<StatsSystem>, cls: KSTPTargetClass) -> Void {
    this.AddMod(stats, KSTPStats.TrackStatFor(cls), gameStatModifierType.Multiplier, 0.00);
  }

  // PREFERRED. Track stats are left exactly as the weapon and the player's
  // cyberware set them; only the time-to-lock multiplier for the denied class is
  // inflated, so a permitted component always wins the race for the same target.
  private final func DenySoft(stats: ref<StatsSystem>, cls: KSTPTargetClass) -> Void {
    let stat: gamedataStatType = KSTPStats.TimeToLockStatFor(cls);
    if Equals(stat, gamedataStatType.Invalid) {
      return;
    };
    let k: Float = KSTPStats.SuppressionMultiplier();
    let base: Float = stats.GetStatValue(this.m_target, stat);
    if base > 0.001 {
      // Scale rather than swamp: whatever ordering the weapon, mods and perks
      // established between classes survives, it just moves out of reach.
      this.AddMod(stats, stat, gameStatModifierType.Multiplier, k);
    } else {
      // A neutral-zero base would swallow any Multiplier. Fall back to additive
      // so the suppression still lands.
      this.AddMod(stats, stat, gameStatModifierType.Additive, k);
    };
  }

  // SmartGunTrackMultipleEntitiesInADS (orphans.script:2789) is named as if it
  // governs multi-target tracking while aiming, and nothing in the 2.31 script dump
  // reads it, so its effect is unproven. -1 leaves vanilla alone and is the
  // shipping default.
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
    // Additive delta against the live value, the way ripperdoc.script:517 zeroes
    // HumanityAllocated: the only way to land on an absolute target with a
    // reversible modifier.
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
      // Only tracked once the game has accepted it, so Clear never tries to
      // remove something that was never there.
      ArrayPush(this.m_applied, data);
    } else {
      let statName: String = EnumValueToString("gamedataStatType", Cast<Int64>(EnumInt(stat)));
      this.Log(s"AddModifier refused \(statName)");
    };
  }

  // -------------------------------------------------------------------------
  // Removal
  // -------------------------------------------------------------------------

  public final func RemoveApplied() -> Void {
    if ArraySize(this.m_applied) == 0 {
      this.ForgetTarget();
      return;
    };
    let stats: ref<StatsSystem> = GameInstance.GetStatsSystem(this.GetGameInstance());
    let i: Int32 = 0;
    while i < ArraySize(this.m_applied) {
      // Removing from a stats object whose entity is already gone is a no-op,
      // which is the required behavior on the unequip path.
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

  // -------------------------------------------------------------------------
  // Re-latch
  // -------------------------------------------------------------------------

  // Soft re-latch. EnableSmartGunHandlerEvent (orphans.script:61871) is the event
  // vehicle combat uses to switch the weapon's native smart-gun handler on and off
  // (vehicleTransition.script:2424-2435); bouncing it drives the handler to
  // re-initialize and re-read the weapon's stat block. Off now, on next frame, so
  // the native side sees two distinct transitions.
  //
  // Skipped while mounted: in a vehicle vanilla drives `enable` from the aim
  // button, and forcing it true there would leave the handler on outside ADS
  // until the next aim change.
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

  // Hard re-latch. Re-equips the weapon outright (EquipmentManipulationAction.ReequipWeapon,
  // orphans.script:11218, the action WaitForEquipEvents uses at
  // upperBodyTransitions.script:1948), which tears the weapon entity down and
  // rebuilds it, and with it anything latched at draw time. Costs a visible draw
  // animation, so it is never automatic; only KSTPBodyPart.ForceReequip() calls it.
  //
  // No re-entrancy guard is needed: the unequip/equip pair this fires arrives
  // through the slot callback, and re-applying the protocol against the rebuilt
  // weapon is exactly the intended outcome.
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

  // -------------------------------------------------------------------------
  // Introspection: the diagnostic surface. Kept as queries rather than log calls
  // so this module stays dependency-free.
  // -------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Public facade: the interface in docs/ARCHITECTURE.md
// ---------------------------------------------------------------------------

public class KSTPBodyPart {

  // Translate a protocol's body-part axis into stat modifiers on the held smart
  // weapon. Always clears first, so calling this repeatedly cannot stack.
  // Safe to call with no weapon in hand: the protocol is remembered and applied
  // when one is drawn.
  public final static func Apply(gi: GameInstance, p: ref<KSTPProtocol>) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.ApplyProtocol(p);
  }

  // Full stop. Removes every applied modifier and forgets the protocol, so a
  // later weapon swap does not silently re-arm. Use Reapply() if you only wanted
  // to refresh.
  public final static func Clear(gi: GameInstance) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.RemoveApplied();
    state.SetProtocolCleared();
  }

  // Re-run the last-applied protocol against whatever is in hand now.
  public final static func Reapply(gi: GameInstance) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.ApplyProtocol(state.GetProtocol());
  }

  // Force the native smart-gun handler to pick these stats up again.
  //
  // The handler re-reads the SmartGun* stats live, so a protocol change normally
  // binds at once. Where that is not confirmed for an install, the stats count as
  // latched when the weapon comes up, the modifiers have to be in place before that
  // latch, and a caller changing the protocol mid-draw calls this afterwards.
  // ApplyProtocol runs the soft path automatically whenever
  // KSTPGate.LiveStatReread() is false.
  public final static func ForceRefresh(gi: GameInstance) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.CycleSmartGunHandler(KSTPBodyPart.GetHeldSmartWeapon(gi));
  }

  // The heavy hammer: re-equip the weapon so everything latched at draw time is
  // rebuilt. It costs a visible draw animation, so it serves diagnostics and a
  // manual "reapply now" action rather than routine protocol changes.
  public final static func ForceReequip(gi: GameInstance) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if !IsDefined(state) {
      return;
    };
    state.RequestReequip();
  }

  // -------------------------------------------------------------------------

  // The seven classes, in KSTPTargetClass ordinal order. Redscript has no enum
  // reflection; this list and KSTPTargetClassCount() are maintained together.
  public final static func AllClasses() -> array<KSTPTargetClass> = [
    KSTPTargetClass.Head,
    KSTPTargetClass.Chest,
    KSTPTargetClass.Leg,
    KSTPTargetClass.WeakSpot,
    KSTPTargetClass.Mechanical,
    KSTPTargetClass.Breach,
    KSTPTargetClass.Vehicle
  ]

  // The held weapon, but only if it is a smart weapon: the SmartGun* stats mean
  // nothing on anything else. Right hand then left, matching
  // ScriptedPuppet.GetActiveWeapon (scriptedPuppet.script:1787).
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

  // Which stats object a weapon's SmartGun* stats live on.
  //
  // Vanilla resolves applicationTarget "Weapon", the path Items.KiroshiOpticsFragment1
  // takes to put SmartGunTrackLegComponents on the held gun, as
  // weapon.GetItemData().GetStatsObjectID() (effector.script:33). That is the
  // authority and the default here. The entity-derived
  // Cast<StatsObjectID>(weapon.GetEntityID()) form is what the combat code uses for
  // other weapon stats (aiActionHelper.script:555); `useEntity` selects it, and it
  // is also the fallback when itemData yields no valid object.
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

  // Isolates the one cross-module dependency this file has. KSTPGate lives in
  // KSTP.Core; with the gate off the conservative route is taken and a re-latch is
  // forced after every apply.
  public final static func LiveRereadConfirmed() -> Bool {
    return KSTPGate.LiveStatReread();
  }

  // -------------------------------------------------------------------------
  // Diagnostics
  // -------------------------------------------------------------------------

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

  // Diagnostic knob: switch which stats object is targeted and re-apply in place.
  public final static func SetUseEntityStatsObject(gi: GameInstance, v: Bool) -> Void {
    let state: ref<KSTPBodyPartState> = KSTPBodyPartState.Get(gi);
    if IsDefined(state) {
      state.SetUseEntityStatsObject(v);
    };
  }
}
