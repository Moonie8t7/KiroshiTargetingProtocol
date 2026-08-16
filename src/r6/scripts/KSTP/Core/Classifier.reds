// Kiroshi Smart Targeting Protocol: the read side.
//
// KSTPClassifier turns a tracked GameObject into a KSTPClassification (Types.reds) and
// answers the policy question "does the active protocol permit this target?".
//
// Nothing in this file mutates the world. It reads records, one stat, and one attitude
// agent. The smart-gun HUD calls Classify() once per tracked candidate per frame, so
// anything with a side effect here would fire at frame rate.
//
// All game symbols referenced here exist in the 2.31 decompiled dump; file:line citations
// are on the non-obvious ones.

module KSTP.Core

// ---------------------------------------------------------------------------
// Cached immutable axes
//
// Affiliation, NPC type, rarity and the netrunner archetype flag are fixed at spawn and
// are the expensive half of a classification (TweakDB record fetch + a stats query).
//
// Not cached:
//   attitude            group-relational, changes the instant the player trips an alarm
//   isCivilian/isPolice/isGanger
//                       all three are m_is* fields recomputed by
//                       ScriptedPuppet.RefreshCachedReactionPresetData()
//                       (scriptedPuppet.script:1351-1355) from the live reaction preset
//                       group, so a cop who drops police behavior flips them mid-session
// ---------------------------------------------------------------------------

class KSTPClassAxes {
  // Kept so a hash collision on the Uint32 EntityID hash is detected rather than silently
  // returning another entity's faction.
  public let id: EntityID;

  // Affiliation_Record.EnumName(), raw, and the same name with android variants folded to
  // their parent faction. Both are kept: policy matches raw-then-folded, and the raw name
  // is what a protocol author sees when they single out an android variant on purpose.
  // The gamedataAffiliation ordinal is not stored. A mod-added faction ships an
  // Affiliation_Record with a real EnumName but cannot extend the compiled RTTI enum, so
  // the name is the only key that works for every faction.
  public let affiliation: CName;
  public let affiliationFolded: CName;
  public let affiliationLabel: String;

  public let npcType: gamedataNPCType;
  public let rarity: gamedataNPCRarity;
  public let isNetrunner: Bool;

  // Character_Record.IsCrowd() (orphans.script:16424): the record-level, spawn-fixed half
  // of crowd membership. The note at its use in Classify() explains why the
  // ScriptedPuppet-level accessor is avoided.
  public let isCrowdRecord: Bool;
}

// ---------------------------------------------------------------------------
// Cache + hoisted player reference
//
// Redscript has no static class fields, so the mutable state lives on a ScriptableSystem.
// That supplies the session lifecycle: the container builds one instance per game session
// and calls OnAttach/OnDetach around it, and PlayerAttach/PlayerDetach requests bracket
// every player swap (Johnny possession, cutscene doubles, replaced player entities). Each
// of those is a point where cached EntityIDs stop meaning anything, so each one clears.
// ---------------------------------------------------------------------------

public class KSTPClassifierCache extends ScriptableSystem {

  private let m_axes: ref<inkHashMap>;
  private let m_count: Int32;
  private let m_player: wref<GameObject>;

  // Hard ceiling on cached entities. Entries are evicted individually only by the
  // ScriptedPuppet.OnDetach hook at the bottom of this file, so a long session in a dense
  // district would otherwise grow without bound. Clearing the whole map is safe because
  // every entry is re-derivable on the next Classify() call. m_count is an approximation
  // (a Set over an existing key double-counts) and errs toward clearing early, which costs
  // a re-read and nothing else.
  private final static func Capacity() -> Int32 = 512

  public final static func Get(gi: GameInstance) -> ref<KSTPClassifierCache> {
    let container: ref<ScriptableSystemsContainer> = GameInstance.GetScriptableSystemsContainer(gi);
    if !IsDefined(container) {
      return null;
    };
    return container.Get(n"KSTP.Core.KSTPClassifierCache") as KSTPClassifierCache;
  }

  // For the two contract entry points that take no GameInstance. Returns null outside a
  // session, which every caller here treats as "nothing to do".
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

  // The hoist. GameObject.HasAttitude (gameObject.script:494) runs
  // GameInstance.GetPlayerSystem(...).GetLocalPlayerMainGameObject() on every invocation,
  // and IsHostile(), IsNeutral() and IsFriendly() are each one HasAttitude call, so a plain
  // "if npc.IsHostile()" costs a PlayerSystem lookup per candidate per frame, and two when
  // neutral is tested as well. The player is resolved once per session here and its
  // attitude agent handed back; on ScriptedPuppet that agent is a stored component
  // (scriptedPuppet.script:1086).
  public final func GetPlayerAttitudeAgent() -> ref<AttitudeAgent> {
    if !IsDefined(this.m_player) {
      // Lazy re-resolve: covers the first Classify() before any PlayerAttachRequest lands,
      // and any case where the player entity was replaced without one.
      this.m_player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
      if !IsDefined(this.m_player) {
        return null;
      };
    };
    return this.m_player.GetAttitudeAgent();
  }

  public final func Lookup(id: EntityID) -> wref<KSTPClassAxes> {
    if !IsDefined(this.m_axes) {
      return null;
    };
    let entry: wref<KSTPClassAxes> = this.m_axes.Get(KSTPClassifierCache.KeyOf(id)) as KSTPClassAxes;
    if !IsDefined(entry) {
      return null;
    };
    // EntityID.GetHash is Uint32 (orphans.script:11864), so collisions are possible.
    // Treat one as a miss; Store() overwrites the loser.
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

// ---------------------------------------------------------------------------
// KSTPClassifier
// ---------------------------------------------------------------------------

public class KSTPClassifier {

  // -------------------------------------------------------------------------
  // Contract surface
  // -------------------------------------------------------------------------

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
        // The entity has no usable record yet: mid-spawn, or a GameObject subclass with
        // no character or vehicle record at all. Do not cache a blank; the next frame gets
        // another chance to read it properly.
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
      // TRAP (c): IsPrevention() and NCPD affiliation are separate axes and disagree in
      // both directions. IsPrevention() is `return this.IsCharacterPolice();`
      // (scriptedPuppet.script:1553), and IsCharacterPolice() reads the m_isPolice field,
      // which is set from the reaction preset group string
      // (scriptedPuppet.script:1351-1355) and never from affiliation. An NPC on a Police
      // reaction preset trips IsPrevention() whatever it is affiliated with, and an
      // NCPD-affiliated NPC on any other preset fails it. Vanilla relies on the gap:
      // preventionSystem.script:458 excludes AndroidNCPD_NotPrevention and
      // HazmatNCPD_NotPrevention units from police behavior by tag while leaving their
      // NCPD affiliation intact.
      //
      // The two answer different questions, so isPolice is their union and the HUD's
      // Police bucket is complete. Affiliation stays on the classification for anything
      // that has to tell "is a cop" from "works for NCPD".
      c.isPolice = puppet.IsPrevention() || Equals(axes.affiliationFolded, n"NCPD");
      c.isCivilian = puppet.IsCharacterCivilian();
      // Record-level crowd flag, not ScriptedPuppet.IsCrowd() (scriptedPuppet.script:1425),
      // which decompiles to
      //     this.GetRecord().IsCrowd() || IsDefined(this.GetCrowdMemberComponent()) ? ... : false
      // whose printed precedence would call IsInCrowd() on a possibly-null component. That
      // is most likely a decompiler artifact of `a || (b ? c : false)`, and resolving it is
      // not worth doing at frame rate. The record flag is also the half this classification
      // wants: it says "this is a crowd archetype", where the component half says only
      // whether a crowd member is inside its crowd right now.
      c.isCrowd = axes.isCrowdRecord;
      c.threat = KSTPClassifier.DeriveThreat(axes, c, puppet.IsCharacterGanger());
    } else {
      c.isPolice = Equals(axes.affiliationFolded, n"NCPD");
      c.isCivilian = false;
      c.isCrowd = false;
      c.threat = KSTPClassifier.DeriveNonPuppetThreat(obj);
    };

    return c;
  }

  // The policy predicate. Pure: protocol and classification in, verdict out. It does not
  // consult KSTPGate. The gate decides whether Enforcement/Faction.reds may act, while the
  // HUD colors by verdict on every build (Types.reds:63-66). Reading the gate here would
  // make the overlay lie on an install where enforcement is off.
  public final static func Permits(p: ref<KSTPProtocol>, c: ref<KSTPClassification>) -> Bool {
    // No protocol, or nothing readable: vanilla behavior. Never refuse on ignorance.
    if !IsDefined(p) || !IsDefined(c) || !c.valid {
      return true;
    };

    // factionFilterEnabled is the master switch for the whole target-side axis. attitudeMask,
    // allowCivilians and allowedAffiliations all sit under the same gated block in
    // Types.reds and are inert while it is false.
    if !p.factionFilterEnabled {
      return true;
    };

    // Attitude. Re-read every Classify() call, never cached.
    if c.attitudeKnown {
      if Equals(p.attitudeMask, KSTPAttitudeMask.HostileOnly) && NotEquals(c.attitude, EAIAttitude.AIA_Hostile) {
        return false;
      };
      if Equals(p.attitudeMask, KSTPAttitudeMask.HostileAndNeutral) && Equals(c.attitude, EAIAttitude.AIA_Friendly) {
        return false;
      };
      // KSTPAttitudeMask.Any imposes nothing.
    };
    // TRAP (a): when attitudeKnown is false there is no attitude agent to ask. Turrets,
    // most devices, and any vehicle whose m_attitudeAgent was never populated land here.
    // The mask cannot be evaluated, so it abstains instead of refusing. Refusing would make
    // every faction protocol silently unable to lock a turret, which reads as a broken mod.

    // Non-combatants, by three independent routes. The affiliation record is the third:
    // gamedataAffiliation.Civilian (orphans.script:4412) is carried by NPCs whose reaction
    // preset is not a Civilian_* one, so testing the m_isCivilian flag alone misses them.
    // Civilian has no Android variant, so the raw name suffices and no fold is needed,
    // which matters because FoldAffiliation's fallback branch builds a String and this runs
    // once per tracked candidate per frame.
    if !p.allowCivilians && (c.isCivilian || c.isCrowd || Equals(c.affiliation, n"Civilian")) {
      return false;
    };

    // Affiliation deny-list, checked ahead of the allow-list and independently of its size.
    // A named refusal has to outrank the unlisted catch-all below, or unticking a faction in
    // the menu would do nothing while "Allow unlisted factions" is on, and that is the
    // shipped default. Same raw-then-folded match as the allow-list.
    if ArraySize(p.deniedAffiliations) > 0 && IsNameValid(c.affiliation) {
      if ArrayContains(p.deniedAffiliations, c.affiliation)
      || ArrayContains(p.deniedAffiliations, KSTPClassifier.FoldAffiliation(c.affiliation)) {
        return false;
      };
    };

    // Affiliation allow-list. Empty list means "no affiliation restriction".
    if ArraySize(p.allowedAffiliations) > 0 {
      if !IsNameValid(c.affiliation) {
        // Same abstention as attitude: unknown affiliation is not a refusal.
        return true;
      };
      // TRAP (b): match on both the raw and the folded name. Raw first, so a protocol that
      // singles out n"MaelstromAndroid" still works and so the common permitted case costs
      // nothing; FoldAffiliation's fallback branch builds a String, and this runs once per
      // tracked candidate per frame. Folded second, which catches a protocol that lists
      // n"Maelstrom" against a MaelstromAndroid target.
      if !ArrayContains(p.allowedAffiliations, c.affiliation)
      && !ArrayContains(p.allowedAffiliations, KSTPClassifier.FoldAffiliation(c.affiliation)) {
        // A miss is a refusal only when the author asked for a hard whitelist. The settings
        // layer surfaces this as "Allow unlisted factions" and defaults it on, because the
        // menu can offer a toggle per vanilla faction only. Mod-added factions, the minor
        // DLC ones and Unaffiliated/Unknown/Classified never appear on the list, so treating
        // a miss as an automatic refusal would silently blank half the world.
        return p.allowUnlistedAffiliations;
      };
    };

    return true;
  }

  public final static func Invalidate(id: EntityID) -> Void {
    let cache: ref<KSTPClassifierCache> = KSTPClassifierCache.GetCurrent();
    if IsDefined(cache) {
      cache.Invalidate(id);
    };
  }

  public final static func ClearCache() -> Void {
    let cache: ref<KSTPClassifierCache> = KSTPClassifierCache.GetCurrent();
    if IsDefined(cache) {
      cache.Clear();
    };
  }

  // -------------------------------------------------------------------------
  // TRAP (b): android affiliation folding
  //
  // gamedataAffiliation (orphans.script:4404-4447) ships four android variants as
  // first-class enum members, separate from their parent gang:
  //     Maelstrom = 10 / MaelstromAndroid = 11
  //     Scavengers = 20 / ScavengersAndroid = 21
  //     SixthStreet = 22 / SixthStreetAndroid = 23
  //     Wraiths = 33 / WraithsAndroid = 34
  // Without folding, a protocol whose allow-list contains n"Maelstrom" refuses every
  // Maelstrom android on the map and gives the player no visible reason.
  //
  // Matching is on CName rather than the enum ordinal, because a mod-added faction cannot
  // extend a compiled RTTI enum but can ship an Affiliation_Record with its own EnumName.
  // The four cases below are the shipped ones; the suffix strip after them covers
  // mod-added <Faction>Android records that follow the same naming convention.
  //
  // Affiliation_Record.EnumName() returns the exact RTTI member name. Vanilla feeds
  // EnumName() straight into EnumValueFromName() elsewhere
  // (tweakAIConditionChecks.script:2660), which works on an exact match only.
  // -------------------------------------------------------------------------

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

  // Gangs, as distinct from corps, law and civilians. Folded names only; call
  // FoldAffiliation first. Corpo security (Arasaka, Militech, Kang Tao, NetWatch,
  // Biotechnica, Zetatech, SSI, Barghest) is excluded because it is not a gang, and
  // including it would make the HUD label wrong for half of Dogtown.
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

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  // Returns null when there is nothing worth caching yet.
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
        // Mid-spawn. Refuse to cache: a puppet classified one frame early would otherwise
        // carry Unknown/Invalid axes for the rest of the session.
        return null;
      };
      affiliation = record.Affiliation();
      axes.npcType = puppet.GetNPCType();
      axes.rarity = puppet.GetNPCRarity();
      axes.isCrowdRecord = record.IsCrowd();
      // IsNetrunnerPuppet() (scriptedPuppet.script:1143) is a live read of the
      // IsNetrunnerArchetype stat. Archetype is assigned at spawn and never changes, so it
      // caches safely once the record is up, which is what the guard above guarantees.
      // Anything that does move it later can call KSTPClassifier.Invalidate().
      axes.isNetrunner = puppet.IsNetrunnerPuppet();
    } else {
      let vehicle: ref<VehicleObject> = obj as VehicleObject;
      if IsDefined(vehicle) {
        let vehicleRecord: wref<Vehicle_Record> = vehicle.GetRecord();
        if !IsDefined(vehicleRecord) {
          return null;
        };
        // Vehicles carry a real Affiliation_Record (orphans.script:20872); vanilla reads it
        // to decide whether a car is NCPD (vehicles.script:467). Smart guns lock vehicle
        // components, so the HUD needs it to say whose car it is.
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

  // Best-effort classification for an entity whose record was not ready. Attitude comes
  // off the component rather than the record and still resolves, so a target mid-spawn
  // keeps a usable IFF color instead of dropping off the overlay for a frame.
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

  // TRAP (a): non-puppets have no attitude agent.
  //
  // The base GameObject.GetAttitudeAgent() returns null (gameObject.script:430);
  // ScriptedPuppet returns its attitude component (scriptedPuppet.script:1086) and
  // VehicleObject returns m_attitudeAgent (vehicles.script:514), which may itself be null.
  // GameObject.GetAttitudeTowards (gameObject.script:451/465) covers all of that by
  // returning AIA_Neutral when either agent is missing, which is indistinguishable from a
  // real neutral reading. A HostileOnly protocol would then treat every turret as "neutral,
  // therefore refused" instead of "unknown, therefore abstain".
  //
  // Both agents are resolved here and the branch is on their existence, which is more
  // accurate than testing IsPuppet(): a vehicle with no agent is caught as well.
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
    // Direction matters and is target -> player, matching vanilla HasAttitude
    // (gameObject.script:494) and IsFriendlyTowardsPlayer (gameObject.script:481).
    // Attitude is not symmetric.
    c.attitude = targetAgent.GetAttitudeTowards(playerAgent);
    c.attitudeKnown = true;
  }

  private final static func AffiliationLabel(record: wref<Affiliation_Record>, enumName: CName) -> String {
    // Vanilla pattern, NPCPuppet.script:3527. LocalizedName() is a LocKey CName, so it goes
    // through LocKeyToString (orphans.script:19941) rather than NameToString.
    let key: CName = record.LocalizedName();
    if IsNameValid(key) {
      let localized: String = LocKeyToString(key);
      if NotEquals(localized, "") {
        return localized;
      };
    };
    // Fall back to the raw enum name, matching NPCPuppet.GetAffiliation()
    // (NPCPuppet.script:698-704), which does the same and nothing else.
    return NameToString(enumName);
  }

  // -------------------------------------------------------------------------
  // Threat derivation
  //
  // KSTPThreatClass belongs to this mod, not to the game. It is an IFF bucket for the HUD,
  // answering what the player is looking at. The component set is KSTPTargetClass and is
  // decided natively.
  //
  // Four independent axes feed it, in this precedence:
  //   1. rarity   (gamedataNPCRarity, orphans.script:4951): MaxTac, Boss, Elite
  //   2. npcType  (gamedataNPCType,   orphans.script:4928): Drone, Mech, Chimera, Spiderbot
  //   3. the IsNetrunnerArchetype stat, via IsNetrunnerPuppet() (scriptedPuppet.script:1143)
  //   4. prevention and reaction-preset flags (IsPrevention(), IsCharacterCivilian(),
  //      IsCharacterGanger()) plus affiliation as a cross-check
  //
  // Rarity outranks type because MaxTac and Boss are the two facts a player needs before
  // any other. Type outranks the netrunner stat because a Chimera is a Chimera whatever
  // archetype stats it carries. The netrunner stat outranks Elite because an incoming quickhack
  // is more actionable than a larger health pool.
  // -------------------------------------------------------------------------

  private final static func DeriveThreat(axes: wref<KSTPClassAxes>, c: ref<KSTPClassification>, isGangerPreset: Bool) -> KSTPThreatClass {
    // Vanilla carries two definitions of MaxTac. This takes the rarity one:
    //
    //   rarity-based: ScriptedPuppet.IsMaxTac() (scriptedPuppet.script:1310) is
    //       Equals(this.GetNPCRarity(), gamedataNPCRarity.MaxTac)
    //   registry-based: PreventionSystem.IsPreventionMaxTac() (preventionSystem.script:3483)
    //       walks PoliceAgentRegistry.GetMaxTacNPCList() (policeAgentsRegistry.script:112-122)
    //
    // The registry answers whether a unit is part of the currently-running MaxTac response.
    // It is a linear scan of a live list, it changes as the heat stage moves, it is empty
    // for MaxTac spawned by a quest rather than by prevention, and MaxTac-rarity NPCs tagged
    // MaxTac_NotPrevention (preventionSystem.script:461) are excluded from it by design.
    //
    // Rarity is used because it is immutable and therefore cacheable, it needs no system
    // lookup in a per-frame path, and an IFF readout wants the unit's identity rather than
    // its current place on prevention's roster.
    if Equals(axes.rarity, gamedataNPCRarity.MaxTac) {
      return KSTPThreatClass.MaxTac;
    };
    if Equals(axes.rarity, gamedataNPCRarity.Boss) {
      return KSTPThreatClass.Boss;
    };

    // Machines. Android is absent from this test: gang androids (MaelstromAndroid and the
    // rest) are humanoid combatants that the player reads as gang members. Vanilla's
    // IsMechanical() (scriptedPuppet.script:1147) groups them with drones for damage-type
    // purposes, which is a different question from IFF. They fall through to the faction
    // logic below.
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

    // isPolice is already the union of the prevention flag and NCPD affiliation; see the
    // TRAP (c) note in Classify().
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

  // Non-puppets. Turrets are the only device class worth a bucket of its own; smart guns
  // track their mechanical components and the player wants to tell a turret apart from a
  // parked car at a glance.
  private final static func DeriveNonPuppetThreat(obj: wref<GameObject>) -> KSTPThreatClass {
    if IsDefined(obj as SecurityTurret) {
      return KSTPThreatClass.Turret;
    };
    // Vehicles land here. KSTPThreatClass has no Vehicle member by design: the vehicle axis
    // is a KSTPTargetClass, and the classification still carries the vehicle's affiliation
    // and attitude for the HUD to render.
    return KSTPThreatClass.Unknown;
  }
}

// ---------------------------------------------------------------------------
// Cache hygiene
//
// Drop an entity's cached axes when it detaches from the world. One hash remove, and it
// keeps churn in a dense district from reaching the capacity ceiling. The capacity reset
// in KSTPClassifierCache.Store() remains the backstop for anything that leaves without
// this firing.
//
// Nothing is mutated on the puppet here, so there is nothing to restore. This file is
// read-only against the world.
// ---------------------------------------------------------------------------

@wrapMethod(ScriptedPuppet)
protected cb func OnDetach() -> Bool {
  wrappedMethod();
  KSTPClassifier.Invalidate(this.GetEntityID());
}
