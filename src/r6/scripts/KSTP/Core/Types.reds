// Kiroshi Smart Targeting Protocol: shared types.
//
// Every module in this mod codes against the declarations in this file. Nothing here
// touches the game beyond enum values verified in the decompiled 2.31 script dump.
// Keep it dependency-free so it can be loaded first.

module KSTP.Core

// ---------------------------------------------------------------------------
// Target component classes
//
// These mirror the seven gamedataStatType entries the native smart-gun handler
// reads (orphans.script:2784-2791). The ordinals below are local to this mod and
// carry no game meaning; KSTPStats.TrackStatFor() and TimeToLockStatFor() map them
// onto the real stat types.
// ---------------------------------------------------------------------------

enum KSTPTargetClass {
  Head = 0,
  Chest = 1,
  Leg = 2,
  WeakSpot = 3,
  Mechanical = 4,
  Breach = 5,
  Vehicle = 6,
}

// Count of the above. Redscript has no enum reflection, so this is maintained by hand.
public static func KSTPTargetClassCount() -> Int32 = 7

// ---------------------------------------------------------------------------
// Policy
// ---------------------------------------------------------------------------

// How a policy treats targets that fall outside it.
//   Strict:    excluded classes are turned off entirely (track stat -> 0)
//   Preferred: excluded classes stay lockable but lock much slower (time-to-lock
//              multiplier inflated), so permitted classes win the race
enum KSTPLockPolicy {
  Strict = 0,
  Preferred = 1,
}

// Which attitudes the protocol will engage. Attitude is read live, never cached.
enum KSTPAttitudeMask {
  HostileOnly = 0,
  HostileAndNeutral = 1,
  Any = 2,
}

// A complete targeting protocol. One of these is active at a time.
public class KSTPProtocol {
  public let id: Int32;
  public let displayName: String;

  // Body-part axis. Index by KSTPTargetClass ordinal, length KSTPTargetClassCount().
  public let allowedClasses: array<Bool>;
  public let lockPolicy: KSTPLockPolicy;

  // Multi-entity ADS tracking (gamedataStatType.SmartGunTrackMultipleEntitiesInADS,
  // orphans.script:2789). -1 means "leave vanilla alone".
  public let multiEntityADS: Int32;

  // Faction axis. Gated: enforced only while KSTPGate.FactionAxisEnabled() is true.
  // Populated regardless, so the HUD can color-code by policy even on a build where
  // enforcement is switched off.
  public let factionFilterEnabled: Bool;
  // Keyed on Affiliation_Record.EnumName() (CName), not on the gamedataAffiliation
  // integer: mod-added factions cannot extend a compiled RTTI enum.
  public let allowedAffiliations: array<CName>;
  // Affiliations the author named and refused outright. Distinct from "simply absent
  // from allowedAffiliations", and checked before it. Without this list, allowUnlisted
  // below would readmit every faction the player switched off, because an unticked
  // faction and a faction the menu has never heard of look identical once the allow-list
  // is built. Same CName keying, and android variants are listed alongside their parent.
  public let deniedAffiliations: array<CName>;
  // How a target whose affiliation is valid but absent from allowedAffiliations is treated.
  //   true:  allowedAffiliations is a preference list; anything unlisted still passes
  //   false: allowedAffiliations is a hard whitelist; anything unlisted is refused
  // Only consulted when allowedAffiliations is non-empty; an empty list means "no
  // affiliation restriction". Defaults to true so a partially-filled list cannot
  // silently refuse every mod-added or minor faction the author never thought about.
  public let allowUnlistedAffiliations: Bool;
  public let attitudeMask: KSTPAttitudeMask;
  public let allowCivilians: Bool;

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

// ---------------------------------------------------------------------------
// Classification
//
// The read side. Every field here is obtainable from pure redscript and is inert:
// no AI reaction, no attitude mutation, no wanted-level side effect.
// ---------------------------------------------------------------------------

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

public class KSTPClassification {
  public let valid: Bool;

  // True when the entity is a ScriptedPuppet. Devices and vehicles are lockable
  // (SmartGunTrackVehicleComponents and SmartGunTrackMechanicalComponents exist) but
  // have no Character_Record and no attitude agent. GetAttitudeTowards silently
  // reports AIA_Neutral for them, so branch on this before trusting `attitude`.
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

  public static func Invalid() -> ref<KSTPClassification> {
    let c: ref<KSTPClassification> = new KSTPClassification();
    c.valid = false;
    c.threat = KSTPThreatClass.Unknown;
    return c;
  }
}

// ---------------------------------------------------------------------------
// Stat mapping
//
// The bridge from KSTPTargetClass to the real gamedataStatType values the native
// handler reads. Verified against orphans.script:2775-2791.
// ---------------------------------------------------------------------------

public class KSTPStats {

  // Weapon-side: whether the smart gun tracks this component class at all.
  // Vanilla base weapon ships Chest=3, Leg=2, Mechanical=1.
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

  // Target-side: how long this component class takes to lock. Inflating this on the
  // target NPC's StatsObjectID is how PREFERRED works and is also the whole mechanism
  // behind the faction axis; a large enough multiplier stops the lock from completing.
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

  // Multiplier applied to a de-prioritized or denied class. Large enough that the
  // lock realistically never completes, small enough to stay well inside float range.
  public static func SuppressionMultiplier() -> Float = 1000.0
}

