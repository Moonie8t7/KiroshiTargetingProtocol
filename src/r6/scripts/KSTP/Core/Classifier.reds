// Kiroshi Smart Targeting Protocol: classification and policy.
//
// Provides KSTPClassifier.Classify(), which resolves a tracked GameObject to a
// KSTPClassification (Types.reds), and Permits()/PermitsCoded(), the pure policy predicate
// over a KSTPProtocol. Read-only against the world: Classify() runs once per tracked
// candidate per frame, so nothing here may carry a side effect.
//
// file:line citations refer to the decompiled 2.31 scripts.

module KSTP.Core

// The spawn-fixed half of a classification: the axes that cost a TweakDB record fetch and a
// stats query. Attitude is excluded because it is group-relational, and isCivilian/isPolice/
// isGanger because they are m_is* fields recomputed from the live reaction preset group by
// ScriptedPuppet.RefreshCachedReactionPresetData() (scriptedPuppet.script:1351-1355).

class KSTPClassAxes {
  // Detects a collision on the Uint32 EntityID hash used as the cache key.
  public let id: EntityID;

  // Affiliation_Record.EnumName() raw, and the same name with android variants folded to the
  // parent faction. Policy matches raw then folded, and the raw name is what a protocol author
  // sees when singling out an android variant on purpose. The gamedataAffiliation ordinal is
  // not stored: a mod-added faction ships an Affiliation_Record with a real EnumName but cannot
  // extend the compiled RTTI enum, so the name is the only key valid for every faction.
  public let affiliation: CName;
  public let affiliationFolded: CName;
  public let affiliationLabel: String;

  public let npcType: gamedataNPCType;
  public let rarity: gamedataNPCRarity;
  public let isNetrunner: Bool;

  // Character_Record.IsCrowd() (orphans.script:16424): the record-level, spawn-fixed half of
  // crowd membership, not the ScriptedPuppet accessor. See Classify().
  public let isCrowdRecord: Bool;
}

// Session-scoped store for KSTPClassAxes, plus a hoisted player reference. Redscript has no
// static class fields, so the mutable state lives on a ScriptableSystem: the container brackets
// it with OnAttach/OnDetach, and PlayerAttach/PlayerDetach requests bracket every player swap
// (Johnny possession, cutscene doubles, replaced player entities). Cached EntityIDs stop
// meaning anything at each of those points, so each one clears.

public class KSTPClassifierCache extends ScriptableSystem {

  private let m_axes: ref<inkHashMap>;
  private let m_count: Int32;
  private let m_player: wref<GameObject>;

  // Hard ceiling on cached entities. Individual eviction happens only through the
  // ScriptedPuppet.OnDetach hook at the foot of this file, so a long session in a dense
  // district would otherwise grow without bound. Clearing the whole map is safe, every entry
  // being re-derivable on the next Classify(). m_count is an approximation (a Set over an
  // existing key double-counts) and errs toward clearing early.
  private final static func Capacity() -> Int32 = 512

  public final static func Get(gi: GameInstance) -> ref<KSTPClassifierCache> {
    let container: ref<ScriptableSystemsContainer> = GameInstance.GetScriptableSystemsContainer(gi);
    if !IsDefined(container) {
      return null;
    };
    return container.Get(n"KSTP.Core.KSTPClassifierCache") as KSTPClassifierCache;
  }

  // For the contract entry points that take no GameInstance. Returns null outside a session,
  // which every caller here treats as "nothing to do".
  public final static func GetCurrent() -> ref<KSTPClassifierCache> {
    let container: ref<ScriptableSystemsContainer> = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
    if !IsDefined(container) {
      return null;
    };
    return container.Get(n"KSTP.Core.KSTPClassifierCache") as KSTPClassifierCache;
  }

  private func OnAttach() {
    this.m_axes = new inkHashMap();
    this.m_count = 0;
  }

  private func OnDetach() {
    this.Clear();
    this.m_axes = null;
  }

  private final func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    this.Clear();
    this.m_player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
  }

  private final func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    this.Clear();
    this.m_player = null;
  }

  // The player's attitude agent, resolved once per session. GameObject.HasAttitude
  // (gameObject.script:494) re-runs GetLocalPlayerMainGameObject() on every invocation, and
  // IsHostile(), IsNeutral() and IsFriendly() are one HasAttitude call each, so a plain
  // npc.IsHostile() costs a PlayerSystem lookup per candidate per frame. Re-resolves lazily
  // when the reference is missing, which covers the first Classify() before any
  // PlayerAttachRequest lands and any player entity replaced without one.
  public final func GetPlayerAttitudeAgent() -> ref<AttitudeAgent> {
    if !IsDefined(this.m_player) {
      this.m_player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
      if !IsDefined(this.m_player) {
        return null;
      };
    };
    return this.m_player.GetAttitudeAgent();
  }

  // Returns null on a miss and on a hash collision: EntityID.GetHash is Uint32
  // (orphans.script:11864), and Store() overwrites the loser.
  public final func Lookup(id: EntityID) -> wref<KSTPClassAxes> {
    if !IsDefined(this.m_axes) {
      return null;
    };
    let entry: wref<KSTPClassAxes> = this.m_axes.Get(KSTPClassifierCache.KeyOf(id)) as KSTPClassAxes;
    if !IsDefined(entry) {
      return null;
    };
    if entry.id != id {
      return null;
    };
    return entry;
  }

  public final func Store(entry: ref<KSTPClassAxes>) -> Void {
    if !IsDefined(this.m_axes) || !IsDefined(entry) {
      return;
    };
    if this.m_count >= KSTPClassifierCache.Capacity() {
      this.Clear();
    };
    this.m_axes.Set(KSTPClassifierCache.KeyOf(entry.id), entry);
    this.m_count += 1;
  }

  public final func Invalidate(id: EntityID) -> Void {
    if !IsDefined(this.m_axes) {
      return;
    };
    if this.m_axes.Remove(KSTPClassifierCache.KeyOf(id)) && this.m_count > 0 {
      this.m_count -= 1;
    };
  }

  public final func Clear() -> Void {
    if IsDefined(this.m_axes) {
      this.m_axes.Clear();
    };
    this.m_count = 0;
  }

  private final static func KeyOf(id: EntityID) -> Uint64 {
    return Cast<Uint64>(EntityID.GetHash(id));
  }
}

// Classification and policy. Every entry point is static and safe to call from a per-frame
// handler.

public class KSTPClassifier {

  // --- Contract surface ---

  // Classifies a tracked candidate. Returns an invalid classification for a null object or an
  // undefined EntityID, and a best-effort one for an entity whose record is not ready yet.
  // Never returns null.
  public final static func Classify(obj: wref<GameObject>) -> ref<KSTPClassification> {
    if !IsDefined(obj) {
      return KSTPClassification.Invalid();
    };

    let id: EntityID = obj.GetEntityID();
    if !EntityID.IsDefined(id) {
      return KSTPClassification.Invalid();
    };

    let cache: ref<KSTPClassifierCache> = KSTPClassifierCache.Get(obj.GetGame());
    let axes: wref<KSTPClassAxes>;
    if IsDefined(cache) {
      axes = cache.Lookup(id);
    };
    if !IsDefined(axes) {
      let fresh: ref<KSTPClassAxes> = KSTPClassifier.ReadAxes(obj, id);
      if !IsDefined(fresh) {
        // Never cache a blank: the entity is mid-spawn or carries no record at all, and the
        // next frame gets another chance to read it.
        return KSTPClassifier.ClassifyWithoutAxes(obj, cache);
      };
      if IsDefined(cache) {
        cache.Store(fresh);
      };
      axes = fresh;
    };

    let c: ref<KSTPClassification> = new KSTPClassification();
    c.valid = true;
    c.isPuppet = obj.IsPuppet();

    c.affiliation = axes.affiliation;
    c.affiliationLabel = axes.affiliationLabel;
    c.rarity = axes.rarity;
    c.npcType = axes.npcType;
    c.isNetrunner = axes.isNetrunner;

    KSTPClassifier.ReadAttitude(obj, cache, c);

    let puppet: ref<ScriptedPuppet> = obj as ScriptedPuppet;
    if IsDefined(puppet) {
      // IsPrevention() and NCPD affiliation are separate axes that disagree in both
      // directions. IsPrevention() returns IsCharacterPolice() (scriptedPuppet.script:1553),
      // which reads m_isPolice from the reaction preset group (scriptedPuppet.script:1351-1355)
      // and never from affiliation. Vanilla relies on the gap: preventionSystem.script:458
      // drops AndroidNCPD_NotPrevention and HazmatNCPD_NotPrevention from police behaviour by
      // tag while leaving their NCPD affiliation intact. isPolice is therefore the union, and
      // affiliation stays on the classification for callers that must tell "is a cop" from
      // "works for NCPD".
      c.isPolice = puppet.IsPrevention() || Equals(axes.affiliationFolded, n"NCPD");
      c.isCivilian = puppet.IsCharacterCivilian();
      // Record-level crowd flag, not ScriptedPuppet.IsCrowd() (scriptedPuppet.script:1425),
      // which decompiles to an expression whose printed precedence calls IsInCrowd() on a
      // possibly-null component and which answers whether a crowd member is inside its crowd
      // right now rather than whether the archetype is a crowd one.
      c.isCrowd = axes.isCrowdRecord;
      c.threat = KSTPClassifier.DeriveThreat(axes, c, puppet.IsCharacterGanger());
    } else {
      c.isPolice = Equals(axes.affiliationFolded, n"NCPD");
      c.isCivilian = false;
      c.isCrowd = false;
      c.isVehicle = IsDefined(obj as VehicleObject);
      c.threat = KSTPClassifier.DeriveNonPuppetThreat(obj);
    };

    return c;
  }

  // Why PermitsCoded() permitted or refused, as a code rather than a string: no allocation and
  // no interpolation, so the reasoning is carried on the hot path and rendered as text only at
  // a trace site. PermitReasonName() maps these; keep the two in step.
  public static func KSTP_ReasonUnreadable() -> Int32 = 0
  public static func KSTP_ReasonVehicleClass() -> Int32 = 1
  public static func KSTP_ReasonFilterOff() -> Int32 = 2
  public static func KSTP_ReasonAttitude() -> Int32 = 3
  public static func KSTP_ReasonCivilian() -> Int32 = 4
  public static func KSTP_ReasonDeniedList() -> Int32 = 5
  public static func KSTP_ReasonAllowListMiss() -> Int32 = 6
  public static func KSTP_ReasonUnknownAffiliation() -> Int32 = 7
  public static func KSTP_ReasonPassedAll() -> Int32 = 8

  // Verdict only. Thin wrapper so the per-frame call sites pay nothing for the reason code.
  public final static func Permits(p: ref<KSTPProtocol>, c: ref<KSTPClassification>) -> Bool {
    let reason: Int32;
    return KSTPClassifier.PermitsCoded(p, c, reason);
  }

  // The policy predicate: protocol and classification in, verdict and reason code out. Pure,
  // and blind to KSTPGate by design: the gate decides whether Enforcement/Faction.reds may
  // act, while the HUD colours by verdict on every build, so reading it here would make the
  // overlay lie on an install with enforcement off. Ignorance never refuses: an unreadable
  // target, an unknown attitude and an unknown affiliation all permit.
  public final static func PermitsCoded(p: ref<KSTPProtocol>, c: ref<KSTPClassification>, out reason: Int32) -> Bool {
    if !IsDefined(p) || !IsDefined(c) || !c.valid {
      reason = KSTPClassifier.KSTP_ReasonUnreadable();
      return true;
    };

    // Vehicle is the one target class that refuses rather than steers, so it is tested on the
    // axis that can deny a target, and above the faction switch because a class decision must
    // hold with faction filtering off. The body-part classes cannot deny anything: the native
    // handler falls back to a raw head slot when no enabled class matches
    // (weapon.script:1526). This verdict drives the overlay label; exclusion itself is enforced
    // by the class mask in Enforcement/BodyPart.reds. See ADR 0013.
    if c.isVehicle && !p.Allows(KSTPTargetClass.Vehicle) {
      reason = KSTPClassifier.KSTP_ReasonVehicleClass();
      return false;
    };

    // Master switch for the whole target-side axis: attitudeMask, allowCivilians and
    // allowedAffiliations are inert while it is false.
    if !p.factionFilterEnabled {
      reason = KSTPClassifier.KSTP_ReasonFilterOff();
      return true;
    };

    if c.attitudeKnown {
      if Equals(p.attitudeMask, KSTPAttitudeMask.HostileOnly) && NotEquals(c.attitude, EAIAttitude.AIA_Hostile) {
        reason = KSTPClassifier.KSTP_ReasonAttitude();
        return false;
      };
      if Equals(p.attitudeMask, KSTPAttitudeMask.HostileAndNeutral) && Equals(c.attitude, EAIAttitude.AIA_Friendly) {
        reason = KSTPClassifier.KSTP_ReasonAttitude();
        return false;
      };
    };
    // attitudeKnown false means there is no agent to ask: turrets, most devices, and any
    // vehicle whose m_attitudeAgent was never populated. The mask abstains rather than
    // refusing, or every faction protocol would be unable to lock a turret.

    // Non-combatants by three independent routes. The affiliation record is the third:
    // gamedataAffiliation.Civilian (orphans.script:4412) is carried by NPCs whose reaction
    // preset is not a Civilian_* one, so the m_isCivilian flag alone misses them. Civilian has
    // no Android variant, so the raw name suffices and no fold is paid on this per-frame path.
    // The flag defaults to permitting; see ADR 0005.
    if !p.allowCivilians && (c.isCivilian || c.isCrowd || Equals(c.affiliation, n"Civilian")) {
      reason = KSTPClassifier.KSTP_ReasonCivilian();
      return false;
    };

    // The deny-list is checked ahead of the allow-list and independently of its size: a named
    // refusal must outrank the unlisted catch-all below, or unticking a faction in the menu
    // would do nothing while "Allow unlisted factions" is on, which is the shipped default.
    if ArraySize(p.deniedAffiliations) > 0 && IsNameValid(c.affiliation) {
      if ArrayContains(p.deniedAffiliations, c.affiliation)
      || ArrayContains(p.deniedAffiliations, KSTPClassifier.FoldAffiliation(c.affiliation)) {
        reason = KSTPClassifier.KSTP_ReasonDeniedList();
        return false;
      };
    };

    // An empty allow-list means no affiliation restriction.
    if ArraySize(p.allowedAffiliations) > 0 {
      if !IsNameValid(c.affiliation) {
        reason = KSTPClassifier.KSTP_ReasonUnknownAffiliation();
        return true;
      };
      // Raw first, so a protocol that singles out n"MaelstromAndroid" still works and the
      // common permitted case costs nothing; FoldAffiliation()'s fallback branch builds a
      // String. Folded second, catching a protocol that lists n"Maelstrom" against a
      // MaelstromAndroid target.
      if !ArrayContains(p.allowedAffiliations, c.affiliation)
      && !ArrayContains(p.allowedAffiliations, KSTPClassifier.FoldAffiliation(c.affiliation)) {
        // A miss refuses only under a hard whitelist. The menu can offer a toggle per vanilla
        // faction only, so mod-added factions, the minor DLC ones and
        // Unaffiliated/Unknown/Classified never appear on the list; "Allow unlisted factions"
        // defaults on for that reason.
        reason = KSTPClassifier.KSTP_ReasonAllowListMiss();
        return p.allowUnlistedAffiliations;
      };
    };

    reason = KSTPClassifier.KSTP_ReasonPassedAll();
    return true;
  }

  // Renders a code from PermitsCoded. Trace sites only; never called on the hot path.
  public final static func PermitReasonName(code: Int32) -> String {
    if code == KSTPClassifier.KSTP_ReasonUnreadable()         { return "no protocol or unreadable target"; };
    if code == KSTPClassifier.KSTP_ReasonVehicleClass()       { return "VEHICLE target class is off"; };
    if code == KSTPClassifier.KSTP_ReasonFilterOff()          { return "faction filter disabled"; };
    if code == KSTPClassifier.KSTP_ReasonAttitude()           { return "attitude mask"; };
    if code == KSTPClassifier.KSTP_ReasonCivilian()           { return "civilians not allowed"; };
    if code == KSTPClassifier.KSTP_ReasonDeniedList()         { return "faction unticked in the menu"; };
    if code == KSTPClassifier.KSTP_ReasonAllowListMiss()      { return "not on the allow-list"; };
    if code == KSTPClassifier.KSTP_ReasonUnknownAffiliation() { return "affiliation unknown, abstained"; };
    if code == KSTPClassifier.KSTP_ReasonPassedAll()          { return "passed every rule"; };
    return "unmapped(" + ToString(code) + ")";
  }

  // Drops one entity's cached axes. Required after anything that moves a spawn-fixed axis.
  public final static func Invalidate(id: EntityID) -> Void {
    let cache: ref<KSTPClassifierCache> = KSTPClassifierCache.GetCurrent();
    if IsDefined(cache) {
      cache.Invalidate(id);
    };
  }

  // Drops every cached entry. Safe at any time; axes are re-derived on the next Classify().
  public final static func ClearCache() -> Void {
    let cache: ref<KSTPClassifierCache> = KSTPClassifierCache.GetCurrent();
    if IsDefined(cache) {
      cache.Clear();
    };
  }

  // --- Affiliation folding ---

  // Maps an android variant to its parent faction. gamedataAffiliation
  // (orphans.script:4404-4447) ships Maelstrom, Scavengers, SixthStreet and Wraiths android
  // variants as first-class enum members separate from the parent gang, so an allow-list
  // holding n"Maelstrom" would otherwise refuse every Maelstrom android on the map with no
  // visible reason. Matching is on CName rather than the enum ordinal, because a mod-added
  // faction cannot extend a compiled RTTI enum but can ship an Affiliation_Record with its own
  // EnumName; the suffix strip covers mod-added <Faction>Android records. EnumName() returns
  // the exact RTTI member name, which vanilla feeds straight into EnumValueFromName()
  // (tweakAIConditionChecks.script:2660) on an exact match only.
  public final static func FoldAffiliation(name: CName) -> CName {
    if Equals(name, n"MaelstromAndroid")   { return n"Maelstrom"; };
    if Equals(name, n"ScavengersAndroid")  { return n"Scavengers"; };
    if Equals(name, n"SixthStreetAndroid") { return n"SixthStreet"; };
    if Equals(name, n"WraithsAndroid")     { return n"Wraiths"; };
    if !IsNameValid(name) {
      return name;
    };
    let s: String = NameToString(name);
    let n: Int32 = StrLen(s);
    if n > 7 && Equals(StrRight(s, 7), "Android") {
      return StringToName(StrLeft(s, n - 7));
    };
    return name;
  }

  // Gangs, as distinct from corps, law and civilians. Takes a folded name; call
  // FoldAffiliation() first. Corpo security (Arasaka, Militech, Kang Tao, NetWatch,
  // Biotechnica, Zetatech, SSI, Barghest) is excluded because it is not a gang, and including
  // it would make the HUD label wrong for half of Dogtown.
  public final static func IsGangAffiliation(folded: CName) -> Bool {
    return Equals(folded, n"Animals")
        || Equals(folded, n"Maelstrom")
        || Equals(folded, n"Scavengers")
        || Equals(folded, n"SixthStreet")
        || Equals(folded, n"TheMox")
        || Equals(folded, n"TygerClaws")
        || Equals(folded, n"Valentinos")
        || Equals(folded, n"VoodooBoys")
        || Equals(folded, n"Wraiths")
        || Equals(folded, n"Aldecaldos")
        || Equals(folded, n"AfterlifeMercs")
        || Equals(folded, n"highriders");
  }

  // --- Reads ---

  // Reads the spawn-fixed axes. Returns null when the record is not up yet, which the caller
  // must treat as "nothing worth caching": a puppet classified one frame early would carry
  // Unknown/Invalid axes for the rest of the session.
  private final static func ReadAxes(obj: wref<GameObject>, id: EntityID) -> ref<KSTPClassAxes> {
    let affiliation: wref<Affiliation_Record>;
    let axes: ref<KSTPClassAxes> = new KSTPClassAxes();
    axes.id = id;
    axes.npcType = gamedataNPCType.Invalid;
    axes.rarity = gamedataNPCRarity.Invalid;

    let puppet: ref<ScriptedPuppet> = obj as ScriptedPuppet;
    if IsDefined(puppet) {
      let record: ref<Character_Record> = puppet.GetRecord();
      if !IsDefined(record) {
        return null;
      };
      affiliation = record.Affiliation();
      axes.npcType = puppet.GetNPCType();
      axes.rarity = puppet.GetNPCRarity();
      axes.isCrowdRecord = record.IsCrowd();
      // IsNetrunnerPuppet() (scriptedPuppet.script:1143) is a live read of the
      // IsNetrunnerArchetype stat. Archetype is assigned at spawn and never changes, so it
      // caches safely once the record is up; anything that does move it must call
      // KSTPClassifier.Invalidate().
      axes.isNetrunner = puppet.IsNetrunnerPuppet();
    } else {
      let vehicle: ref<VehicleObject> = obj as VehicleObject;
      if IsDefined(vehicle) {
        let vehicleRecord: wref<Vehicle_Record> = vehicle.GetRecord();
        if !IsDefined(vehicleRecord) {
          return null;
        };
        // Vehicles carry a real Affiliation_Record (orphans.script:20872); vanilla reads it to
        // decide whether a car is NCPD (vehicles.script:467).
        affiliation = vehicleRecord.Affiliation();
      } else {
        // Devices and everything else: no record, no faction. The empty result is still
        // cached, so the casts are not re-tested on a turret every frame.
        axes.affiliation = n"";
        axes.affiliationFolded = n"";
        axes.affiliationLabel = "";
        return axes;
      };
    };

    if IsDefined(affiliation) {
      axes.affiliation = affiliation.EnumName();
      axes.affiliationFolded = KSTPClassifier.FoldAffiliation(axes.affiliation);
      axes.affiliationLabel = KSTPClassifier.AffiliationLabel(affiliation, axes.affiliation);
    } else {
      axes.affiliation = n"";
      axes.affiliationFolded = n"";
      axes.affiliationLabel = "";
    };

    return axes;
  }

  // Best-effort classification for an entity whose record was not ready. Attitude comes off the
  // component rather than the record and still resolves, so a target mid-spawn keeps a usable
  // IFF colour instead of dropping off the overlay for a frame.
  private final static func ClassifyWithoutAxes(obj: wref<GameObject>, cache: ref<KSTPClassifierCache>) -> ref<KSTPClassification> {
    let c: ref<KSTPClassification> = new KSTPClassification();
    c.valid = true;
    c.isPuppet = obj.IsPuppet();
    c.affiliation = n"";
    c.affiliationLabel = "";
    c.rarity = gamedataNPCRarity.Invalid;
    c.npcType = gamedataNPCType.Invalid;
    c.threat = KSTPThreatClass.Unknown;
    KSTPClassifier.ReadAttitude(obj, cache, c);
    return c;
  }

  // Sets attitude and, separately, whether attitude is known at all. Non-puppets frequently
  // have no agent: the base GameObject.GetAttitudeAgent() returns null (gameObject.script:430),
  // ScriptedPuppet returns its attitude component (scriptedPuppet.script:1086), and
  // VehicleObject returns m_attitudeAgent (vehicles.script:514), which may itself be null.
  // GameObject.GetAttitudeTowards (gameObject.script:451/465) hides all of that by returning
  // AIA_Neutral when either agent is missing, indistinguishable from a real neutral reading,
  // which would make a HostileOnly protocol refuse every turret. Branching on agent existence
  // rather than IsPuppet() also catches a vehicle with no agent.
  private final static func ReadAttitude(obj: wref<GameObject>, cache: ref<KSTPClassifierCache>, c: ref<KSTPClassification>) -> Void {
    c.attitude = EAIAttitude.AIA_Neutral;
    c.attitudeKnown = false;
    if !IsDefined(cache) {
      return;
    };
    let targetAgent: ref<AttitudeAgent> = obj.GetAttitudeAgent();
    if !IsDefined(targetAgent) {
      return;
    };
    let playerAgent: ref<AttitudeAgent> = cache.GetPlayerAttitudeAgent();
    if !IsDefined(playerAgent) {
      return;
    };
    // Direction is target -> player, as in HasAttitude (gameObject.script:494) and
    // IsFriendlyTowardsPlayer (gameObject.script:481). Attitude is not symmetric.
    c.attitude = targetAgent.GetAttitudeTowards(playerAgent);
    c.attitudeKnown = true;
  }

  // Localised faction name, falling back to the raw enum name as NPCPuppet.GetAffiliation()
  // does (NPCPuppet.script:698-704).
  private final static func AffiliationLabel(record: wref<Affiliation_Record>, enumName: CName) -> String {
    // LocalizedName() is a LocKey CName, so it resolves through LocKeyToString
    // (orphans.script:19941) rather than NameToString. Vanilla pattern, NPCPuppet.script:3527.
    let key: CName = record.LocalizedName();
    if IsNameValid(key) {
      let localized: String = LocKeyToString(key);
      if NotEquals(localized, "") {
        return localized;
      };
    };
    return NameToString(enumName);
  }

  // --- Threat derivation ---

  // The HUD's IFF bucket. KSTPThreatClass belongs to this mod, not to the game; the component
  // set a lock may use is KSTPTargetClass and is decided natively. Four axes feed it, in
  // precedence order: rarity (gamedataNPCRarity, orphans.script:4951), npcType
  // (gamedataNPCType, orphans.script:4928), the IsNetrunnerArchetype stat via
  // IsNetrunnerPuppet() (scriptedPuppet.script:1143), then the prevention and reaction-preset
  // flags with affiliation as a cross-check. Rarity outranks type because MaxTac and Boss are
  // the facts a player needs first; type outranks the netrunner stat because a Chimera is a
  // Chimera whatever archetype stats it carries; the netrunner stat outranks Elite because an
  // incoming quickhack is more actionable than a larger health pool.
  private final static func DeriveThreat(axes: wref<KSTPClassAxes>, c: ref<KSTPClassification>, isGangerPreset: Bool) -> KSTPThreatClass {
    // Rarity, not the prevention registry. Vanilla carries both definitions of MaxTac:
    // ScriptedPuppet.IsMaxTac() (scriptedPuppet.script:1310) tests gamedataNPCRarity.MaxTac,
    // while PreventionSystem.IsPreventionMaxTac() (preventionSystem.script:3483) scans
    // PoliceAgentRegistry.GetMaxTacNPCList() (policeAgentsRegistry.script:112-122), a live list
    // that moves with the heat stage, is empty for quest-spawned MaxTac, and by design excludes
    // units tagged MaxTac_NotPrevention (preventionSystem.script:461). Rarity is immutable and
    // therefore cacheable, needs no system lookup on a per-frame path, and states the unit's
    // identity rather than its current place on prevention's roster.
    if Equals(axes.rarity, gamedataNPCRarity.MaxTac) {
      return KSTPThreatClass.MaxTac;
    };
    if Equals(axes.rarity, gamedataNPCRarity.Boss) {
      return KSTPThreatClass.Boss;
    };

    // Android is deliberately absent from the machine test: gang androids are humanoid
    // combatants the player reads as gang members, and they fall through to the faction logic
    // below. IsMechanical() (scriptedPuppet.script:1147) groups them with drones for damage
    // type, which is a different question from IFF.
    if Equals(axes.npcType, gamedataNPCType.Drone) || Equals(axes.npcType, gamedataNPCType.Spiderbot) {
      return KSTPThreatClass.Drone;
    };
    if Equals(axes.npcType, gamedataNPCType.Mech)
    || Equals(axes.npcType, gamedataNPCType.Chimera)
    || Equals(axes.npcType, gamedataNPCType.Cerberus) {
      return KSTPThreatClass.Mech;
    };

    if c.isNetrunner {
      return KSTPThreatClass.Netrunner;
    };
    if Equals(axes.rarity, gamedataNPCRarity.Elite) {
      return KSTPThreatClass.Elite;
    };

    // isPolice is already the union of the prevention flag and NCPD affiliation; see Classify().
    if c.isPolice {
      return KSTPThreatClass.Police;
    };
    if c.isCivilian || c.isCrowd {
      return KSTPThreatClass.Civilian;
    };
    if isGangerPreset || KSTPClassifier.IsGangAffiliation(axes.affiliationFolded) {
      return KSTPThreatClass.Ganger;
    };

    return KSTPThreatClass.Unknown;
  }

  // Non-puppets. Turrets earn a bucket of their own because smart guns track their mechanical
  // components and a turret must be distinguishable from a parked car at a glance. Vehicles
  // fall through to Unknown: KSTPThreatClass has no Vehicle member by design, the vehicle axis
  // being a KSTPTargetClass, and the classification still carries the vehicle's affiliation and
  // attitude for the HUD to render.
  private final static func DeriveNonPuppetThreat(obj: wref<GameObject>) -> KSTPThreatClass {
    if IsDefined(obj as SecurityTurret) {
      return KSTPThreatClass.Turret;
    };
    return KSTPThreatClass.Unknown;
  }
}

// Cache hygiene. Drops an entity's cached axes when it detaches from the world, keeping churn
// in a dense district away from the capacity ceiling; the capacity reset in
// KSTPClassifierCache.Store() remains the backstop for anything that leaves without this
// firing. Nothing is mutated on the puppet, so there is nothing to restore.

@wrapMethod(ScriptedPuppet)
protected cb func OnDetach() -> Bool {
  wrappedMethod();
  KSTPClassifier.Invalidate(this.GetEntityID());
}
