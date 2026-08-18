// Kiroshi Smart Targeting Protocol: the six shipped presets, the persisted active selection,
// and the armed state (KSTP coprocessor installed, smart weapon in the right hand). Every
// accepted change is pushed into KSTP.Enforcement, which owns all weapon and NPC state and
// its restore; nothing here mutates either. Depends on the TweakDB records authored by
// src/r6/tweaks/KSTP/cyberware.yaml. See ADR 0007 (tier ladder), ADR 0009 (settings are the
// contract).

module KSTP.Core

// Soft dependency (CONTRACT hard rule 5): a load order where Enforcement failed to compile
// degrades to policy tracked but not applied. Idiom from Custom Map Markers
// CustomMarkerSystem.reds:6-7.
@if(ModuleExists("KSTP.Enforcement"))
import KSTP.Enforcement.*

// Quality tier of the installed coprocessor: 1 to 5, or 0 when none is equipped. Plus grades
// count as their base tier, matching how the game presents them.
//
// Every literal below must name a record authored in src/r6/tweaks/KSTP/cyberware.yaml. A
// TweakDBID literal is a compile-time hash and does not require the record to exist, so a
// typo produces no diagnostic: it returns 0 for that tier, makes IsArmed() false, and leaves
// the mod silently inert. Renaming a record in the yaml means editing the matching line here.
//
// Tier buys target-class coverage only; the unlocks are data, applied by the per-tier stat
// group each record points at. The faction axis is not tier-gated (ADR 0009).
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

// True while the right-hand weapon is a smart weapon. The game's own test, copied from
// cyberpunk/player/psm/vehicleTransition.script:2424-2429 (EnableSmartGunHandler), with the
// null checks vanilla omits because it controls its own call site.
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

// Highest coprocessor tier across every cyberware equipment area, or 0 when none is equipped.
// At most one matches in practice, since two coprocessors share a cyberwareType and cannot
// both be equipped.
//
// Compares TweakDBIDs rather than ItemIDs: EquipmentSystemPlayerData.IsEquipped() matches on
// the whole ItemID including its seed (equipmentSystem.script:2467-2487), and the seed of an
// item the player acquired at a ripperdoc is not knowable here.
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

public func KSTP_HasCyberwareInstalled(owner: wref<GameObject>) -> Bool {
  return KSTP_CyberwareTier(owner) > 0;
}

// True when a protocol asks for nothing the vanilla weapon does not already do. Enforcement
// uses this to skip applying modifiers entirely, which is how AUTO stays byte-for-byte
// vanilla.
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

// Owns the preset list, the active selection and the armed state, and pushes every accepted
// change into Enforcement. GetActive() and IsArmed() are safe to call at any point in the
// lifecycle: before attach they report the inert state rather than failing.
public class KSTPPolicySystem extends ScriptableSystem {

  // The only field that belongs in the save. Presets are rebuilt from code every session, so
  // a mod update can change what PRECISION means without migrating saves.
  private persistent let m_activeProtocolId: Int32 = 0;

  private let m_protocols: array<ref<KSTPProtocol>>;
  private let m_player: wref<PlayerPuppet>;

  // Cached: installed cyberware changes only at a ripperdoc, and is refreshed on the loadout
  // hooks. The held weapon changes constantly and is read live.
  private let m_cyberwareTier: Int32;

  private let m_initialized: Bool;

  // Last state actually pushed into Enforcement. m_appliedValid stays false until the first
  // push, so no logic depends on a non-zero field default surviving engine-side construction
  // of a native-derived system.
  private let m_appliedValid: Bool;
  private let m_appliedArmed: Bool;
  private let m_appliedProtocolId: Int32;

  // Bumped on every accepted change. Faction and Overlay poll this to notice a switch instead
  // of subscribing.
  private let m_generation: Int32;

  public static func Get(gi: GameInstance) -> ref<KSTPPolicySystem> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"KSTP.Core.KSTPPolicySystem") as KSTPPolicySystem;
  }

  // -- Lifecycle --------------------------------------------------------------

  private final func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    // GameInstance has no GetSystemRequestsHandler() in the 2.31 dump, so the corpus's usual
    // pre-game test is unavailable; the null check below is the guard.
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

  // Everything applied to the weapon comes off here: stat modifiers on a world entity have no
  // save/restore path of their own (CONTRACT hard rule 4).
  private final func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    this.m_initialized = false;
    this.ClearEnforcement();
    this.m_appliedValid = false;
    this.m_appliedArmed = false;
    this.m_appliedProtocolId = 0;
    this.m_cyberwareTier = 0;
    this.m_player = null;
  }

  // The persisted id came from whatever build wrote the save; a preset may have been removed
  // since.
  private func OnRestored(saveVersion: Int32, gameVersion: Int32) -> Void {
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

  // Re-reads installed cyberware and reapplies. Called by the loadout hooks at the bottom of
  // this file, and safe to call from anywhere else that suspects the loadout moved.
  public func NotifyLoadoutChanged() -> Void {
    if !this.m_initialized {
      return;
    };
    this.m_cyberwareTier = KSTP_CyberwareTier(this.m_player);
    this.Reapply("loadout", false);
  }

  // Called by UI/Settings.reds once it has reconciled the menu onto the presets. The push is
  // forced because a settings edit rewrites the active KSTPProtocol in place and leaves its id
  // alone, which Reapply()'s (armed, protocolId) guard would otherwise swallow. Enforcement
  // clears before it applies, so a forced push on an unchanged menu close changes no state.
  public func OnSettingsChanged() -> Void {
    if !this.m_initialized {
      return;
    };
    this.Reapply("settings", true);
  }

  public func GetGeneration() -> Int32 {
    return this.m_generation;
  }

  // Quality tier of the equipped coprocessor, 1 to 5, or 0 when none is installed. Cached and
  // refreshed on the loadout hooks rather than read live.
  public func GetCyberwareTier() -> Int32 {
    return this.m_cyberwareTier;
  }

  // Whether the faction axis can act. Any installed tier qualifies (ADR 0009). Separate from
  // KSTPGate.FactionAxisEnabled(), which records whether the mechanism works on this build;
  // both must be true for a target to be suppressed.
  public func FactionAxisAvailable() -> Bool {
    return this.m_cyberwareTier > 0;
  }

  // -- Internals --------------------------------------------------------------

  // Idempotent unless `force`: pushes to Enforcement only when the (armed, protocolId) pair
  // moved, so callers may fire this as often as they like without stacking modifiers. That
  // pair is an incomplete description of what Enforcement consumes, because the contents of
  // the active KSTPProtocol can be rewritten in place while its id stays the same; any caller
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

    // Info is safe only because this fires on attach, protocol switch, loadout change and
    // settings close, and nowhere else.
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
    // Called unconditionally: KSTPFaction.Reevaluate() (Faction.reds:73) calls ReleaseAll()
    // with the gate off rather than returning early, which is what strips the
    // SmartGunTimeToLock* modifiers back off suppressed NPCs when E-STAT goes off mid-session
    // or the protocol drops faction filtering (CONTRACT hard rule 4). It reads the active
    // protocol and IsArmed() back off this system, so it must run after m_applied* update.
    KSTPFaction.Reevaluate(this.GetGameInstance());
  }

  @if(!ModuleExists("KSTP.Enforcement"))
  private final func ApplyEnforcement(p: ref<KSTPProtocol>) -> Void {
    KSTPLog.Debug("Enforcement module absent; body-part policy tracked but not applied.");
  }

  @if(ModuleExists("KSTP.Enforcement"))
  private final func ClearEnforcement() -> Void {
    KSTPBodyPart.Clear(this.GetGameInstance());
    // KSTPFaction.ClearAll() (Faction.reds:92) is ungated and a no-op when nothing is held, so
    // the unarmed branch of Reapply() and OnPlayerDetach both route through here. Without it,
    // unequipping the cyberware or holstering strands up to seven x1000 lock-time multipliers
    // on every suppressed NPC for the rest of the session.
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

  // Builds the six shipped presets on first use. Ids are persisted in the save, so an id must
  // not be reused for a different preset.
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

    // PRECISION: head and weak spots. Preferred rather than strict, so a target the optics
    // cannot headshot is still lockable.
    ArrayPush(this.m_protocols, this.Compose(1, "PRECISION",
      true, false, false, true, false, false, false, KSTPLockPolicy.Preferred));

    // CRIPPLE: legs only, strictly. Nothing else locks.
    ArrayPush(this.m_protocols, this.Compose(2, "CRIPPLE",
      false, false, true, false, false, false, false, KSTPLockPolicy.Strict));

    // ANTI-MACHINE: mechanical and vehicle, per CONTRACT. Breach is its own class in the
    // contract and is not folded in here.
    //
    // KNOWN ISSUE on 2.31: against a human every enabled class is off, and the handler falls
    // back to a raw slot rather than refusing the target (weapon.script:1526), so the lock
    // lands on the chest. SURGICAL leaves humans with no enabled class too and does not fall
    // back, so the fallback is not a pure function of the enabled set. The fix is a threat-
    // class filter on KSTPProtocol, which does not exist yet: see ADR 0006 and ADR 0011.
    ArrayPush(this.m_protocols, this.Compose(3, "ANTI-MACHINE",
      false, false, false, false, true, false, true, KSTPLockPolicy.Strict));

    // ORGANIC: everything except mechanical and vehicle.
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
    // Faction axis stays off on every shipped preset: it is opt-in through UI/Settings.reds
    // and enforced only while KSTPGate.FactionAxisEnabled().
    p.factionFilterEnabled = false;
    // multiEntityADS stays at -1 (vanilla). SmartGunTrackMultipleEntitiesInADS is owned by the
    // settings screen, so a preset does not set it.
    return p;
  }
}

// -- Loadout hooks --
// IsArmed() depends on the right-hand weapon and on installed cyberware. The wraps below are
// the vanilla entry points that fire when either moves; redscript chains @wrapMethod, so they
// coexist with other mods (ADR 0002).

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

// Cyberware produces no weapon-slot event, so the ripperdoc path needs its own hook.
//
// It is the generic equip path, not the cyberware-specific one. InstallCyberwareRequest and
// UninstallCyberwareRequest are declared and handled (equipmentSystem.script:6058, :6065) but
// never constructed anywhere in the 2.31 dump, so wrapping their handlers binds cleanly and
// receives nothing. The ripperdoc queues a plain EquipRequest or UnequipRequest instead
// (ripperdoc.script:1268 and :1454), which reaches EquipmentSystem at :5974 and :6016 and is
// forwarded to EquipmentSystemPlayerData at :4235 and :4335.
//
// The player-data layer is wrapped rather than the system layer: its methods are public, which
// EquipmentSystem's are not, and CyberarmCycle.reds:1646 wraps this exact method in a shipping
// mod. Both fire for every equipment change rather than only cyberware, which is why
// NotifyLoadoutChanged re-reads the tier and defers to Reapply's own no-change guard.
@wrapMethod(EquipmentSystemPlayerData)
public final func OnEquipRequest(request: ref<EquipRequest>) -> Void {
  wrappedMethod(request);
  KSTP_NotifyLoadoutChanged(request.owner);
}

@wrapMethod(EquipmentSystemPlayerData)
public final func OnUnequipRequest(request: ref<UnequipRequest>) -> Void {
  wrappedMethod(request);
  KSTP_NotifyLoadoutChanged(request.owner);
}

// The settings-close signal is owned by UI/Settings.reds, which reconciles the menu onto the
// presets before calling OnSettingsChanged(). This file must not hook it as well.
