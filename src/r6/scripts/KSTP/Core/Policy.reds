// Kiroshi Smart Targeting Protocol: the active protocol and its lifecycle.
//
// This system owns three things:
//   1. the six shipped presets,
//   2. which one is active (persisted into the save),
//   3. whether the mod is currently "armed", meaning KSTP cyberware installed and a
//      smart weapon in the right hand.
//
// Whenever (2) or (3) changes it pushes the result into Enforcement/BodyPart.reds.
// It never touches the weapon or any NPC itself; the stat side lives entirely in
// Enforcement, so the restore-what-you-mutate rule has exactly one owner.

module KSTP.Core

// Enforcement is a sibling module. Guarded so that a load order where Enforcement
// failed to compile degrades to "policy is tracked but not applied" instead of
// taking this file down with it (CONTRACT hard rule 5; idiom copied from
// Custom Map Markers CustomMarkerSystem.reds:6-7).
@if(ModuleExists("KSTP.Enforcement"))
import KSTP.Enforcement.*

// ---------------------------------------------------------------------------
// Identity of the mod's own cyberware.
//
// The implant ships as eleven quality tiers, matching the vanilla cyberware ladder
// (tier 1 through 5++). Each is its own TweakDB record, authored by
// src/r6/tweaks/KSTP/cyberware.yaml. Every record name is written down here and
// nowhere else in script.
//
// EVERY LITERAL BELOW MUST MATCH A RECORD AUTHORED IN cyberware.yaml EXACTLY. A
// TweakDBID literal is a compile-time hash and does not require the record to exist,
// so a typo produces no diagnostic of any kind: it makes KSTP_CyberwareTier() return
// 0 for that tier, IsArmed() false, and the mod silently inert for anyone wearing it.
// Renaming a record in the yaml means editing the matching line here.
//
// Tier drives progression:
//   1  head tracking
//   2  + weak spot
//   3  + breach, and the faction axis becomes enforceable
//   4  + vehicle
//   5  all classes, and permitted classes lock faster
//
// The unlocks themselves are data, applied by the per-tier stat group each record
// points at. This mapping exists so script can gate the faction axis, which is
// behavior rather than a stat.
// ---------------------------------------------------------------------------

// Quality tier of the installed coprocessor: 1 to 5, or 0 when none is equipped.
// Plus grades count as their base tier, matching how the game presents them.
public func KSTP_CyberwareTierOf(id: ItemID) -> Int32 {
  if !ItemID.IsValid(id) {
    return 0;
  };
  if ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorCommon")
     || ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorCommonPlus") {
    return 1;
  };
  if ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorUncommon")
     || ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorUncommonPlus") {
    return 2;
  };
  if ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorRare")
     || ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorRarePlus") {
    return 3;
  };
  if ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorEpic")
     || ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorEpicPlus") {
    return 4;
  };
  if ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorLegendary")
     || ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorLegendaryPlus")
     || ItemID.IsOfTDBID(id, t"Items.KSTPKiroshiIFFCoprocessorLegendaryPlusPlus") {
    return 5;
  };
  return 0;
}

// Tier at which the faction and threat-class axis starts being enforced. Below this
// the overlay still classifies and colors every target, so the feature is visible and
// legible before it is available, which is what makes the upgrade worth buying.
public func KSTP_FactionAxisMinTier() -> Int32 = 3

// ---------------------------------------------------------------------------
// Free helpers, usable from any module without going through the system.
// ---------------------------------------------------------------------------

// The game's own smart-weapon test, copied from
// cyberpunk/player/psm/vehicleTransition.script:2424-2429 (EnableSmartGunHandler),
// with the null checks vanilla omits because it controls its own call site.
public func KSTP_IsHoldingSmartWeapon(owner: wref<GameObject>) -> Bool {
  if !IsDefined(owner) {
    return false;
  };
  let transactionSystem: ref<TransactionSystem> = GameInstance.GetTransactionSystem(owner.GetGame());
  if !IsDefined(transactionSystem) {
    return false;
  };
  let weapon: ref<WeaponObject> = transactionSystem.GetItemInSlot(owner, t"AttachmentSlots.WeaponRight") as WeaponObject;
  if !IsDefined(weapon) {
    return false;
  };
  let record: ref<WeaponItem_Record> = weapon.GetWeaponRecord();
  if !IsDefined(record) {
    return false;
  };
  let evolution: wref<WeaponEvolution_Record> = record.Evolution();
  if !IsDefined(evolution) {
    return false;
  };
  return Equals(evolution.Type(), gamedataWeaponEvolution.Smart);
}

// Walks every cyberware equipment area and returns the tier of the installed
// coprocessor, or 0 when none is equipped. Compares TweakDBIDs rather than ItemIDs:
// EquipmentSystemPlayerData.IsEquipped() matches on the whole ItemID including its seed
// (equipmentSystem.script:2467-2487), and the seed of an item the player acquired at a
// ripperdoc is not knowable here.
//
// Returns the highest tier found. Two coprocessors cannot both be equipped, since they
// share a cyberwareType, so in practice at most one matches.
public func KSTP_CyberwareTier(owner: wref<GameObject>) -> Int32 {
  if !IsDefined(owner) {
    return 0;
  };
  let data: ref<EquipmentSystemPlayerData> = EquipmentSystem.GetData(owner);
  if !IsDefined(data) {
    return 0;
  };
  let best: Int32 = 0;
  let tier: Int32;
  let areas: array<gamedataEquipmentArea> = data.GetAllCyberwareEquipmentAreas();
  let slotCount: Int32;
  let slot: Int32;
  let itemID: ItemID;
  for area in areas {
    slotCount = data.GetNumberOfSlots(area);
    slot = 0;
    while slot < slotCount {
      itemID = data.GetItemInEquipSlot(area, slot);
      tier = KSTP_CyberwareTierOf(itemID);
      if tier > best {
        best = tier;
      };
      slot += 1;
    };
  };
  return best;
}

// Retained so callers that only need presence read clearly.
public func KSTP_HasCyberwareInstalled(owner: wref<GameObject>) -> Bool {
  return KSTP_CyberwareTier(owner) > 0;
}

// True when a protocol asks for nothing the vanilla weapon does not already do.
// Enforcement can use this to skip applying modifiers entirely, which is how AUTO
// stays byte-for-byte vanilla.
public func KSTP_ProtocolIsVanilla(p: ref<KSTPProtocol>) -> Bool {
  if !IsDefined(p) {
    return true;
  };
  if p.multiEntityADS >= 0 {
    return false;
  };
  let i: Int32 = 0;
  while i < ArraySize(p.allowedClasses) {
    if !p.allowedClasses[i] {
      return false;
    };
    i += 1;
  };
  return true;
}

// ---------------------------------------------------------------------------
// The system
// ---------------------------------------------------------------------------

public class KSTPPolicySystem extends ScriptableSystem {

  // The only thing that belongs in the save. Presets are rebuilt from code every
  // session so a mod update can change what PRECISION means without migrating saves.
  private persistent let m_activeProtocolId: Int32 = 0;

  private let m_protocols: array<ref<KSTPProtocol>>;
  private let m_player: wref<PlayerPuppet>;

  // Installed cyberware changes only at a ripperdoc, so it is cached and refreshed
  // on the equipment hooks below. The held weapon changes constantly and is read live.
  private let m_cyberwareTier: Int32;

  private let m_initialized: Bool;

  // Last state actually pushed into Enforcement. m_appliedValid stays false until the
  // first push, so no logic depends on a non-zero field default surviving engine-side
  // construction of a native-derived system.
  private let m_appliedValid: Bool;
  private let m_appliedArmed: Bool;
  private let m_appliedProtocolId: Int32;

  // Bumped on every accepted change. Other modules (Faction, Overlay) can poll this
  // to notice a switch without subscribing to anything.
  private let m_generation: Int32;

  public static func Get(gi: GameInstance) -> ref<KSTPPolicySystem> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"KSTP.Core.KSTPPolicySystem") as KSTPPolicySystem;
  }

  // -- Lifecycle --------------------------------------------------------------

  private final func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    // No pre-game guard is needed: in the main menu there is no local player, and the
    // null check below already leaves the system inert. GameInstance has no
    // GetSystemRequestsHandler() in the 2.31 dump, so the corpus's usual pre-game test
    // is unavailable here anyway.
    this.m_player = GameInstance.GetPlayerSystem(request.owner.GetGame()).GetLocalPlayerMainGameObject() as PlayerPuppet;
    if !IsDefined(this.m_player) {
      KSTPLog.Warn("Player unavailable on attach; targeting protocol stays inert.");
      return;
    };

    this.EnsureProtocols();
    this.ClampActiveId();
    this.m_cyberwareTier = KSTP_CyberwareTier(this.m_player);
    this.m_initialized = true;

    KSTPLog.Info(s"Online. Protocol \(this.GetActive().displayName), gates \(KSTPGate.Describe()).");
    this.Reapply("attach", false);
  }

  private final func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    // Everything applied to the weapon has to come off here. Stat modifiers on a world
    // entity have no save/restore path of their own (CONTRACT hard rule 4).
    this.m_initialized = false;
    this.ClearEnforcement();
    this.m_appliedValid = false;
    this.m_appliedArmed = false;
    this.m_appliedProtocolId = 0;
    this.m_cyberwareTier = 0;
    this.m_player = null;
  }

  private func OnRestored(saveVersion: Int32, gameVersion: Int32) -> Void {
    // The persisted id came from whatever build wrote the save; a preset may have
    // been removed since.
    this.EnsureProtocols();
    this.ClampActiveId();
  }

  // -- Contract interface -----------------------------------------------------

  public func GetActive() -> ref<KSTPProtocol> {
    this.EnsureProtocols();
    let index: Int32 = this.IndexOfId(this.m_activeProtocolId);
    if index < 0 {
      index = 0;
    };
    return this.m_protocols[index];
  }

  public func SetActive(id: Int32) -> Void {
    this.EnsureProtocols();
    if this.IndexOfId(id) < 0 {
      KSTPLog.Warn(s"Ignoring switch to unknown protocol id \(id).");
      return;
    };
    if id == this.m_activeProtocolId {
      return;
    };
    this.m_activeProtocolId = id;
    KSTPLog.Info(s"Protocol -> \(this.GetActive().displayName).");
    this.Reapply("protocol", false);
  }

  public func CycleNext() -> Void {
    this.EnsureProtocols();
    let count: Int32 = ArraySize(this.m_protocols);
    if count <= 0 {
      return;
    };
    let index: Int32 = this.IndexOfId(this.m_activeProtocolId);
    if index < 0 {
      index = 0;
    };
    this.SetActive(this.m_protocols[(index + 1) % count].id);
  }

  public func GetAll() -> array<ref<KSTPProtocol>> {
    this.EnsureProtocols();
    return this.m_protocols;
  }

  // Cyberware half is cached (rare, expensive); weapon half is live (frequent, cheap).
  public func IsArmed() -> Bool {
    if !this.m_initialized || this.m_cyberwareTier <= 0 {
      return false;
    };
    return KSTP_IsHoldingSmartWeapon(this.m_player);
  }

  // -- Change notifications ---------------------------------------------------

  // Called by the equipment hooks at the bottom of this file. Also safe to call from
  // anywhere else that suspects the loadout moved.
  public func NotifyLoadoutChanged() -> Void {
    if !this.m_initialized {
      return;
    };
    this.m_cyberwareTier = KSTP_CyberwareTier(this.m_player);
    this.Reapply("loadout", false);
  }

  // Gates and settings live outside the save, so they can change while the world is
  // loaded. UI/Settings.reds calls this once it has reconciled the menu onto the presets.
  //
  // The push is forced. Reapply()'s normal guard keys on (armed, protocolId) and a
  // settings edit moves neither: UI/Settings.reds KSTPSettings.ApplyTo rewrites the
  // active KSTPProtocol in place (allowedClasses, lockPolicy, multiEntityADS,
  // factionFilterEnabled, allowedAffiliations) and leaves its id alone. Without the force
  // flag the guard swallows the push, and an unticked class or a STRICT/PREFERRED flip
  // does nothing until the player holsters and redraws. Enforcement clears before it
  // applies, so a forced push on an unchanged menu close costs one remove/re-add of the
  // same modifiers and changes no state.
  public func OnSettingsChanged() -> Void {
    if !this.m_initialized {
      return;
    };
    this.Reapply("settings", true);
  }

  public func GetGeneration() -> Int32 {
    return this.m_generation;
  }

  // Quality tier of the equipped coprocessor, 1 to 5, or 0 when none is installed.
  // Cached and refreshed on the equipment hooks rather than read live, because
  // cyberware only changes at a ripperdoc.
  public func GetCyberwareTier() -> Int32 {
    return this.m_cyberwareTier;
  }

  // Whether the installed tier is high enough to enforce the faction and threat-class
  // axis. Below the threshold the overlay still classifies and colors targets, so the
  // player can see what a protocol would refuse before owning the tier that refuses it.
  //
  // Separate from KSTPGate.FactionAxisEnabled(), which records whether the mechanism
  // works on this build at all. Both must be true for a target to be suppressed.
  public func FactionAxisAvailable() -> Bool {
    return this.m_cyberwareTier >= KSTP_FactionAxisMinTier();
  }

  // -- Internals --------------------------------------------------------------

  // Idempotent by default: pushes to Enforcement only when the (armed, protocol) pair
  // actually moved, so callers may fire this as often as they like. Never stacks
  // modifiers, because Enforcement clears before it applies.
  //
  // `force` skips that guard. The (armed, protocolId) pair is an incomplete description
  // of what Enforcement consumes: the contents of the active KSTPProtocol can be
  // rewritten in place by the settings screen while its id stays the same. Any caller
  // that has mutated a protocol rather than switched to a different one must pass true.
  private final func Reapply(reason: String, force: Bool) -> Void {
    if !this.m_initialized {
      return;
    };
    let armed: Bool = this.IsArmed();
    let id: Int32 = this.m_activeProtocolId;
    // Bool has no OperatorEqual overload in redscript; Equals() is the vanilla idiom
    // for this (see gameObject.script:2625).
    if !force && this.m_appliedValid && Equals(armed, this.m_appliedArmed) && id == this.m_appliedProtocolId {
      return;
    };
    this.m_appliedValid = true;
    this.m_appliedArmed = armed;
    this.m_appliedProtocolId = id;
    this.m_generation += 1;

    // Info rather than Debug: this fires only on attach, protocol switch, loadout change
    // and settings close, and it is the line a bug report needs. `armed` decides whether
    // the proactive half of enforcement runs at all, and a report showing armed=false
    // after a settings close points at the weapon not counting as in-hand while the pause
    // menu is open.
    KSTPLog.Info(s"reapply(\(reason)): armed=\(armed) protocol=\(this.GetActive().displayName)");

    if armed {
      this.ApplyEnforcement(this.GetActive());
    } else {
      this.ClearEnforcement();
    };
  }

  @if(ModuleExists("KSTP.Enforcement"))
  private final func ApplyEnforcement(p: ref<KSTPProtocol>) -> Void {
    KSTPBodyPart.Apply(this.GetGameInstance(), p);
    // The faction axis is the second half of enforcement and has to be driven from the
    // same place, or it never releases. KSTPFaction.Reevaluate() (Faction.reds:73) is
    // callable with the gate off: in that state it calls ReleaseAll() instead of
    // returning early. Calling it unconditionally here is what strips the
    // SmartGunTimeToLock* modifiers back off every suppressed NPC when the player turns
    // E-STAT off mid-session or switches to a protocol without faction filtering
    // (CONTRACT hard rule 4). It reads the active protocol and IsArmed() back off this
    // system, so it must run after m_applied* have been updated; Reapply() guarantees
    // that ordering.
    KSTPFaction.Reevaluate(this.GetGameInstance());
  }

  @if(!ModuleExists("KSTP.Enforcement"))
  private final func ApplyEnforcement(p: ref<KSTPProtocol>) -> Void {
    KSTPLog.Debug("Enforcement module absent; body-part policy tracked but not applied.");
  }

  @if(ModuleExists("KSTP.Enforcement"))
  private final func ClearEnforcement() -> Void {
    KSTPBodyPart.Clear(this.GetGameInstance());
    // Teardown path. KSTPFaction.ClearAll() (Faction.reds:92) is ungated on purpose and
    // is a no-op when nothing is held, so the unarmed branch of Reapply() and
    // OnPlayerDetach both route through here. Without it, unequipping the cyberware or
    // holstering the smart weapon strands up to seven x1000 lock-time multipliers on
    // every suppressed NPC for the rest of the session.
    KSTPFaction.ClearAll(this.GetGameInstance());
  }

  @if(!ModuleExists("KSTP.Enforcement"))
  private final func ClearEnforcement() -> Void {
    // Nothing was applied, so there is nothing to restore.
  }

  private final func IndexOfId(id: Int32) -> Int32 {
    let i: Int32 = 0;
    while i < ArraySize(this.m_protocols) {
      if this.m_protocols[i].id == id {
        return i;
      };
      i += 1;
    };
    return -1;
  }

  private final func ClampActiveId() -> Void {
    if this.IndexOfId(this.m_activeProtocolId) < 0 {
      KSTPLog.Warn(s"Saved protocol id \(this.m_activeProtocolId) no longer exists; falling back to AUTO.");
      this.m_activeProtocolId = 0;
    };
  }

  private final func EnsureProtocols() -> Void {
    if ArraySize(this.m_protocols) > 0 {
      return;
    };

    // Compose() argument order after the name is:
    //   head, chest, leg, weakSpot, mechanical, breach, vehicle, lockPolicy

    // AUTO: vanilla. Everything on, nothing suppressed, no faction axis.
    let auto: ref<KSTPProtocol> = this.Compose(0, "AUTO",
      true, true, true, true, true, true, true, KSTPLockPolicy.Preferred);
    auto.attitudeMask = KSTPAttitudeMask.Any;
    auto.allowCivilians = true;
    ArrayPush(this.m_protocols, auto);

    // PRECISION: bias hard toward head and weak spots. The rest stay lockable, so a
    // target the optics cannot headshot can still be engaged.
    ArrayPush(this.m_protocols, this.Compose(1, "PRECISION",
      true, false, false, true, false, false, false, KSTPLockPolicy.Preferred));

    // CRIPPLE: legs only, strictly. Nothing else locks.
    ArrayPush(this.m_protocols, this.Compose(2, "CRIPPLE",
      false, false, true, false, false, false, false, KSTPLockPolicy.Strict));

    // ANTI-MACHINE: mechanical and vehicle, per CONTRACT. Breach is left off because the
    // contract lists it as its own class, and folding it in here would reinterpret the
    // spec rather than implement it.
    //
    // KNOWN ISSUE on 2.31: ANTI-MACHINE locks the chest of a human rather than refusing
    // the target. Every class a human carries is off in this preset, and the handler
    // falls back to a raw slot when no candidate component is enabled
    // (weapon.script:1526). SURGICAL leaves humans with no enabled class too and does not
    // fall back, so the fallback is not a pure function of the enabled set.
    //
    // The fix is architectural rather than a change of flags here. Which targets may be
    // engaged is the faction and threat axis, which is per-candidate; the body-part
    // classes only decide where on an already-valid target the lock lands. A threat-class
    // filter on KSTPProtocol would express ANTI-MACHINE correctly and does not exist yet.
    ArrayPush(this.m_protocols, this.Compose(3, "ANTI-MACHINE",
      false, false, false, false, true, false, true, KSTPLockPolicy.Strict));

    // ORGANIC: everything except mechanical and vehicle, so drones and parked cars stop
    // eating locks in a crowd fight.
    ArrayPush(this.m_protocols, this.Compose(4, "ORGANIC",
      true, true, true, true, false, true, false, KSTPLockPolicy.Strict));

    // SURGICAL: weak spots only. The narrowest protocol, strict by definition.
    ArrayPush(this.m_protocols, this.Compose(5, "SURGICAL",
      false, false, false, true, false, false, false, KSTPLockPolicy.Strict));
  }

  private final func Compose(id: Int32, name: String, head: Bool, chest: Bool, leg: Bool,
                             weakSpot: Bool, mechanical: Bool, breach: Bool, vehicle: Bool,
                             policy: KSTPLockPolicy) -> ref<KSTPProtocol> {
    let p: ref<KSTPProtocol> = KSTPProtocol.Make(id, name);
    p.SetAllows(KSTPTargetClass.Head, head);
    p.SetAllows(KSTPTargetClass.Chest, chest);
    p.SetAllows(KSTPTargetClass.Leg, leg);
    p.SetAllows(KSTPTargetClass.WeakSpot, weakSpot);
    p.SetAllows(KSTPTargetClass.Mechanical, mechanical);
    p.SetAllows(KSTPTargetClass.Breach, breach);
    p.SetAllows(KSTPTargetClass.Vehicle, vehicle);
    p.lockPolicy = policy;
    // Faction axis stays off on every shipped preset. It is opt-in through
    // UI/Settings.reds and enforced only while KSTPGate.FactionAxisEnabled().
    p.factionFilterEnabled = false;
    // multiEntityADS stays at -1 (vanilla). SmartGunTrackMultipleEntitiesInADS is
    // exposed on the settings screen, so a preset does not set it.
    return p;
  }
}

// ---------------------------------------------------------------------------
// Loadout hooks
//
// IsArmed() depends on the right-hand weapon and on installed cyberware. These are the
// vanilla entry points that fire when either moves. All are @wrapMethod: redscript
// chains multiple wraps of one method, so these coexist with other mods.
// ---------------------------------------------------------------------------

public func KSTP_NotifyLoadoutChanged(owner: wref<GameObject>) -> Void {
  if !IsDefined(owner) || !owner.IsPlayer() {
    return;
  };
  let system: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(owner.GetGame());
  if IsDefined(system) {
    system.NotifyLoadoutChanged();
  };
}

// player.script:1892
@wrapMethod(PlayerPuppet)
protected cb func OnItemAddedToSlot(evt: ref<ItemAddedToSlot>) -> Bool {
  let result: Bool = wrappedMethod(evt);
  if Equals(evt.GetSlotID(), t"AttachmentSlots.WeaponRight") {
    KSTP_NotifyLoadoutChanged(this);
  };
  return result;
}

// player.script:1966
@wrapMethod(PlayerPuppet)
protected cb func OnItemRemovedFromSlot(evt: ref<ItemRemovedFromSlot>) -> Bool {
  let result: Bool = wrappedMethod(evt);
  if Equals(evt.GetSlotID(), t"AttachmentSlots.WeaponRight") {
    KSTP_NotifyLoadoutChanged(this);
  };
  return result;
}

// equipmentSystem.script:4778 and :4783. Cyberware produces no weapon-slot event, so
// the ripperdoc path needs its own hook.
@wrapMethod(EquipmentSystem)
private final func OnInstallCyberwareRequest(request: ref<InstallCyberwareRequest>) -> Void {
  wrappedMethod(request);
  KSTP_NotifyLoadoutChanged(request.owner);
}

@wrapMethod(EquipmentSystem)
private final func OnUninstallCyberwareRequest(request: ref<UninstallCyberwareRequest>) -> Void {
  wrappedMethod(request);
  KSTP_NotifyLoadoutChanged(request.owner);
}

// The settings-close signal is owned by UI/Settings.reds, which reconciles the menu onto
// the presets before calling OnSettingsChanged(). This file must not hook it as well.
