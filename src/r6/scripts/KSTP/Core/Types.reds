// Kiroshi Smart Targeting Protocol: shared type declarations.
//
// Provides the enums and data classes every module codes against, plus the mapping from this
// mod's target classes onto the gamedataStatType values the native handler reads. Enum values
// are verified against the decompiled 2.31 script dump. Dependency-free by contract: it loads
// first and touches no engine state.

module KSTP.Core

// --- Target classes ---

// The seven component classes the native smart-gun handler reads (orphans.script:2784-2791).
// Ordinals are local to this mod and carry no game meaning; KSTPStats maps them onto the real
// stat types.
enum KSTPTargetClass {
  Head = 0,
  Chest = 1,
  Leg = 2,
  WeakSpot = 3,
  Mechanical = 4,
  Breach = 5,
  Vehicle = 6,
}

// Redscript has no enum reflection; kept in step with KSTPTargetClass by hand.
public static func KSTPTargetClassCount() -> Int32 = 7

// --- Policy ---

// Treatment of target classes the protocol excludes. Strict turns them off entirely (track
// stat 0); Preferred leaves them lockable but inflates their time-to-lock multiplier so
// permitted classes win the race.
enum KSTPLockPolicy {
  Strict = 0,
  Preferred = 1,
}

// Attitudes the protocol engages. Attitude is read live, never cached.
enum KSTPAttitudeMask {
  HostileOnly = 0,
  HostileAndNeutral = 1,
  Any = 2,
}

// A complete targeting protocol. One is active at a time.
public class KSTPProtocol {
  public let id: Int32;
  public let displayName: String;

  // Body-part axis, indexed by KSTPTargetClass ordinal, length KSTPTargetClassCount().
  public let allowedClasses: array<Bool>;
  public let lockPolicy: KSTPLockPolicy;

  // gamedataStatType.SmartGunTrackMultipleEntitiesInADS (orphans.script:2789).
  // -1 leaves vanilla alone.
  public let multiEntityADS: Int32;

  // Faction axis, enforced only while KSTPGate.FactionAxisEnabled() is true. Populated
  // regardless, so the HUD can colour-code by protocol on a build where enforcement is off.
  public let factionFilterEnabled: Bool;
  // Keyed on Affiliation_Record.EnumName(), not on the gamedataAffiliation integer: mod-added
  // factions cannot extend a compiled RTTI enum.
  public let allowedAffiliations: array<CName>;
  // Affiliations refused by name, checked before allowedAffiliations and distinct from mere
  // absence, which allowUnlistedAffiliations may readmit. Same CName keying; android variants
  // are listed alongside their parent.
  public let deniedAffiliations: array<CName>;
  // Treatment of an affiliation absent from allowedAffiliations: true makes that list a
  // preference and admits the unlisted, false makes it a hard whitelist. Consulted only when
  // allowedAffiliations is non-empty; an empty list imposes no affiliation restriction.
  public let allowUnlistedAffiliations: Bool;
  public let attitudeMask: KSTPAttitudeMask;
  public let allowCivilians: Bool;

  // Shipping defaults, with every target class permitted and allowedClasses sized to
  // KSTPTargetClassCount().
  public static func Make(id: Int32, name: String) -> ref<KSTPProtocol> {
    let p: ref<KSTPProtocol> = new KSTPProtocol();
    p.id = id;
    p.displayName = name;
    p.lockPolicy = KSTPLockPolicy.Preferred;
    p.multiEntityADS = -1;
    p.factionFilterEnabled = false;
    p.allowUnlistedAffiliations = true;
    p.attitudeMask = KSTPAttitudeMask.HostileAndNeutral;
    p.allowCivilians = false;
    let i: Int32 = 0;
    while i < KSTPTargetClassCount() {
      ArrayPush(p.allowedClasses, true);
      i += 1;
    }
    return p;
  }

  // Ordinals outside allowedClasses are permitted.
  public func Allows(cls: KSTPTargetClass) -> Bool {
    let i: Int32 = EnumInt(cls);
    if i < 0 || i >= ArraySize(this.allowedClasses) { return true; }
    return this.allowedClasses[i];
  }

  public func SetAllows(cls: KSTPTargetClass, v: Bool) -> Void {
    let i: Int32 = EnumInt(cls);
    if i >= 0 && i < ArraySize(this.allowedClasses) {
      this.allowedClasses[i] = v;
    }
  }
}

// --- Classification ---

// Coarse bucket used by the HUD and by faction policy. Derived, not a game enum.
enum KSTPThreatClass {
  Unknown = 0,
  Civilian = 1,
  Police = 2,
  Ganger = 3,
  Netrunner = 4,
  Drone = 5,
  Mech = 6,
  Turret = 7,
  Elite = 8,
  Boss = 9,
  MaxTac = 10,
}

// The read side of a candidate target. Every field is obtainable from pure redscript and is
// inert: no AI reaction, no attitude mutation, no wanted-level side effect.
public class KSTPClassification {
  public let valid: Bool;

  // True when the entity is a ScriptedPuppet. Devices and vehicles are lockable
  // (SmartGunTrackVehicleComponents and SmartGunTrackMechanicalComponents exist) but have no
  // Character_Record and no attitude agent; GetAttitudeTowards silently reports AIA_Neutral
  // for them, so branch on this before trusting `attitude`.
  public let isPuppet: Bool;

  // Affiliation_Record.EnumName(), stable across mods. Empty CName if unavailable.
  public let affiliation: CName;
  // Human-readable, for the HUD. Falls back to the enum name.
  public let affiliationLabel: String;

  public let attitude: EAIAttitude;
  public let attitudeKnown: Bool;

  public let threat: KSTPThreatClass;
  public let rarity: gamedataNPCRarity;
  public let npcType: gamedataNPCType;

  public let isCivilian: Bool;
  public let isPolice: Bool;
  public let isCrowd: Bool;
  public let isNetrunner: Bool;

  // True for a VehicleObject, and the only signal distinguishing a car from a device in the permit
  // decision. Vehicle exclusion is enforced by the class mask, not by lock-time inflation, which
  // was measured to have no effect on a vehicle; this flag drives the overlay verdict. See
  // ADR 0013.
  public let isVehicle: Bool;

  public static func Invalid() -> ref<KSTPClassification> {
    let c: ref<KSTPClassification> = new KSTPClassification();
    c.valid = false;
    c.threat = KSTPThreatClass.Unknown;
    return c;
  }
}

// --- Stat mapping ---

// Bridge from KSTPTargetClass to the gamedataStatType values the native handler reads.
// Verified against orphans.script:2775-2791.
public class KSTPStats {

  // Weapon-side: whether the smart gun tracks this component class at all. The vanilla base
  // weapon ships Chest=3, Leg=2, Mechanical=1.
  public static func TrackStatFor(cls: KSTPTargetClass) -> gamedataStatType {
    switch cls {
      case KSTPTargetClass.Head:       return gamedataStatType.SmartGunTrackHeadComponents;
      case KSTPTargetClass.Chest:      return gamedataStatType.SmartGunTrackChestComponents;
      case KSTPTargetClass.Leg:        return gamedataStatType.SmartGunTrackLegComponents;
      case KSTPTargetClass.WeakSpot:   return gamedataStatType.SmartGunTrackWeakSpotComponents;
      case KSTPTargetClass.Mechanical: return gamedataStatType.SmartGunTrackMechanicalComponents;
      case KSTPTargetClass.Breach:     return gamedataStatType.SmartGunTrackBreachComponents;
      case KSTPTargetClass.Vehicle:    return gamedataStatType.SmartGunTrackVehicleComponents;
    }
    return gamedataStatType.Invalid;
  }

  // Target-side: how long this component class takes to lock. Inflating it on the target NPC's
  // StatsObjectID implements the Preferred policy and the faction axis alike; see ADR 0003.
  public static func TimeToLockStatFor(cls: KSTPTargetClass) -> gamedataStatType {
    switch cls {
      case KSTPTargetClass.Head:       return gamedataStatType.SmartGunTimeToLockHeadComponentMultiplier;
      case KSTPTargetClass.Chest:      return gamedataStatType.SmartGunTimeToLockChestComponentMultiplier;
      case KSTPTargetClass.Leg:        return gamedataStatType.SmartGunTimeToLockLegComponentMultiplier;
      case KSTPTargetClass.WeakSpot:   return gamedataStatType.SmartGunTimeToLockWeakSpotComponentMultiplier;
      case KSTPTargetClass.Mechanical: return gamedataStatType.SmartGunTimeToLockMechanicalComponentMultiplier;
      case KSTPTargetClass.Breach:     return gamedataStatType.SmartGunTimeToLockBreachComponentMultiplier;
      case KSTPTargetClass.Vehicle:    return gamedataStatType.SmartGunTimeToLockVehicleComponentMultiplier;
    }
    return gamedataStatType.Invalid;
  }

  public static func ClassLabel(cls: KSTPTargetClass) -> String {
    switch cls {
      case KSTPTargetClass.Head:       return "HEAD";
      case KSTPTargetClass.Chest:      return "CHEST";
      case KSTPTargetClass.Leg:        return "LIMBS";
      case KSTPTargetClass.WeakSpot:   return "WEAKSPOT";
      case KSTPTargetClass.Mechanical: return "MECHANICAL";
      case KSTPTargetClass.Breach:     return "BREACH";
      case KSTPTargetClass.Vehicle:    return "VEHICLE";
    }
    return "?";
  }

  // Multiplier applied to a de-prioritised or denied class: large enough that the lock never
  // realistically completes, small enough to stay well inside float range.
  public static func SuppressionMultiplier() -> Float = 1000.0
}

