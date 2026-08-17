// Kiroshi Smart Targeting Protocol: Mod Settings integration.
//
// Declares the settings and hotkey classes the menu page is built from, the system that
// reconciles them with the KSTPPolicySystem presets, and the accessors the rest of the mod
// reads them through.
//
// Contract. Every control declared here changes what the game does; see ADR 0009 and ADR 0011.
// No axis owned elsewhere is mirrored: the experiment gates are KSTPGateConfig (Core/Gate.reds)
// and the overlay options are KSTPOverlayConfig (UI/Overlay.reds). Hold-versus-toggle for the
// overlay key is input behaviour and sits on KSTPHotkeys beside the key it modifies.
//
// Dependency. jackhumbert's Mod Settings (red4ext\plugins\mod_settings) is soft. It walks RTTI
// for the @runtimeProperty annotations below, builds the menu page and patches the class
// defaults with the saved values, so `new KSTPSettings()` yields the live configuration. The
// plugin puts module.reds (`module ModSettingsModule`) and packed.reds (`public native class
// ModSettings`) into the compiler's source set, so @if(ModuleExists("ModSettingsModule")) is
// true when it is installed and false when it is not; absent, the annotations are inert and the
// compiled defaults stand. Menu-to-mod refresh runs off the PauseMenuGameController.OnUninitialize
// wrap at the foot of this file and needs nothing from the framework. See ADR 0010.
//
// Annotation pattern follows CP77Mods\Limited HUD LHUD\config.reds; the module-scoped enum as an
// enum setting follows CP77Mods\Custom Map Markers config.reds.
//
// Module placement: the file sits under UI/ but declares module KSTP.Core, because Core/Gate.reds,
// Core/Policy.reds and Enforcement/* all read settings and already sit in KSTP.Core.

module KSTP.Core

// ---------------------------------------------------------------------------
// Settings enums
// ---------------------------------------------------------------------------

// Ordinals are KSTPPolicySystem's protocol ids, assigned in Core/Policy.reds where the presets
// are composed.
public enum KSTPProtocolChoice {
  Auto = 0,
  Precision = 1,
  Cripple = 2,
  AntiMachine = 3,
  Organic = 4,
  Surgical = 5,
}

public enum KSTPLockPolicyChoice {
  Inherit = 0,
  Strict = 1,
  Preferred = 2,
}

public enum KSTPAttitudeChoice {
  Inherit = 0,
  HostileOnly = 1,
  HostileAndNeutral = 2,
  Any = 3,
}

// gamedataStatType.SmartGunTrackMultipleEntitiesInADS is an Int-valued stat; -1 is the
// "leave it alone" sentinel, matching KSTPProtocol.multiEntityADS.
public enum KSTPMultiEntityChoice {
  Inherit = 0,
  ForceOff = 1,
  ForceOn = 2,
}

// ---------------------------------------------------------------------------
// Hotkeys
// ---------------------------------------------------------------------------

// Keybinds, split from KSTPSettings the way LimitedHudHotkeys is so Mod Settings renders them in
// the keybindings group. The `overridableUI` attribute in src/r6/input/kstp_inputs.xml resolves
// against these field names, so the names here and in the XML must stay in lockstep.
public class KSTPHotkeys {

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "UI-Settings-KeyBindings")
  @runtimeProperty("ModSettings.category.order", "30")
  @runtimeProperty("ModSettings.displayName", "Cycle targeting protocol")
  @runtimeProperty("ModSettings.description", "UI-Settings-Bind")
  // Bracket keys, because r6/config/inputUserMappings.xml claims every letter key IK_A..IK_Z on
  // a stock install.
  public let kstpCycleProtocolKey: EInputKey = EInputKey.IK_LeftBracket;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "UI-Settings-KeyBindings")
  @runtimeProperty("ModSettings.category.order", "30")
  @runtimeProperty("ModSettings.displayName", "Show IFF overlay")
  @runtimeProperty("ModSettings.description", "UI-Settings-Bind")
  public let kstpOverlayKey: EInputKey = EInputKey.IK_RightBracket;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "UI-Settings-KeyBindings")
  @runtimeProperty("ModSettings.category.order", "30")
  @runtimeProperty("ModSettings.displayName", "Overlay key is hold-to-show")
  @runtimeProperty("ModSettings.description", "On: the overlay appears while the key is held and goes away when you let go. Off: the key toggles it on and off. This applies when 'Overlay visibility' is set to ONLY WITH THE OVERLAY KEY, and it also lets the key pull the overlay up from the hip when visibility is ONLY WHILE AIMING.")
  public let kstpOverlayHoldMode: Bool = true;
}

// ---------------------------------------------------------------------------
// Main settings page
// ---------------------------------------------------------------------------

// The player-facing configuration. Mod Settings patches the defaults below with the saved values,
// so an instance is always current; KSTPSettingsSystem.ApplyTo stamps it onto the presets.
public class KSTPSettings {

  // -- GENERAL -------------------------------------------------------------

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "General")
  @runtimeProperty("ModSettings.category.order", "0")
  @runtimeProperty("ModSettings.displayName", "Enable Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.description", "Master switch. Off flattens every protocol to vanilla behavior: no stat modifiers are written to the weapon, no target is suppressed, and the overlay reports the protocol as offline.")
  public let masterEnabled: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "General")
  @runtimeProperty("ModSettings.category.order", "0")
  @runtimeProperty("ModSettings.displayName", "Active protocol")
  @runtimeProperty("ModSettings.description", "AUTO is vanilla. PRECISION biases toward heads and weak spots, CRIPPLE takes limbs only, ANTI-MACHINE takes drones and vehicles, ORGANIC skips machines, SURGICAL takes weak spots only. The live value is saved with the game and can also be cycled with the hotkey; this box follows the hotkey and the hotkey follows this box, so it always shows the protocol actually in force.")
  @runtimeProperty("ModSettings.displayValues.Auto", "AUTO")
  @runtimeProperty("ModSettings.displayValues.Precision", "PRECISION")
  @runtimeProperty("ModSettings.displayValues.Cripple", "CRIPPLE")
  @runtimeProperty("ModSettings.displayValues.AntiMachine", "ANTI-MACHINE")
  @runtimeProperty("ModSettings.displayValues.Organic", "ORGANIC")
  @runtimeProperty("ModSettings.displayValues.Surgical", "SURGICAL")
  public let activeProtocol: KSTPProtocolChoice = KSTPProtocolChoice.Auto;

  // -- TARGET CLASSES ------------------------------------------------------
  //
  // These seven toggles are the class mask, unconditionally: whatever is ticked is what the smart
  // gun may lock, whichever protocol is selected, and no second switch gates them. See ADR 0009.
  // Selecting a protocol does not rewrite them; the mask set here survives a protocol change.
  // Vehicle is the one class enforced by exclusion rather than by lock placement, and is
  // hard-denied whatever the lock policy; see ADR 0013.

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Lock HEAD")
  @runtimeProperty("ModSettings.description", "Allow the smart gun to lock head components. Requires a coprocessor of any tier.")
  public let classHead: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Lock CHEST")
  @runtimeProperty("ModSettings.description", "Torso components, the vanilla default class. Turning this off under STRICT makes most humanoids much harder to lock at all.")
  public let classChest: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Lock LIMBS")
  @runtimeProperty("ModSettings.description", "Leg and arm components. Vanilla grants this class through the Kiroshi optics fragment cyberware.")
  public let classLeg: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Lock WEAKSPOT")
  @runtimeProperty("ModSettings.description", "Explicit weak points: fuel tanks, exposed cores, cyberware mounts.")
  public let classWeakSpot: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Lock MECHANICAL")
  @runtimeProperty("ModSettings.description", "Drones, turrets and mechs.")
  public let classMechanical: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Lock BREACH")
  @runtimeProperty("ModSettings.description", "Breach points on armoured targets.")
  public let classBreach: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Lock VEHICLE")
  @runtimeProperty("ModSettings.description", "Vehicle components. Off by default: a smart gun that acquires traffic while you are aiming past it is the single most common way to start a fight you did not want. Turn it on for vehicle combat.")
  public let classVehicle: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Lock policy")
  @runtimeProperty("ModSettings.description", "STRICT turns denied classes off outright, so the reticle never acquires them. PREFERRED leaves them lockable but inflates their time-to-lock, so a permitted class wins the race for the same target. INHERIT uses whatever the selected protocol ships with.")
  @runtimeProperty("ModSettings.displayValues.Inherit", "INHERIT (use protocol default)")
  @runtimeProperty("ModSettings.displayValues.Strict", "STRICT")
  @runtimeProperty("ModSettings.displayValues.Preferred", "PREFERRED")
  public let lockPolicy: KSTPLockPolicyChoice = KSTPLockPolicyChoice.Inherit;

  // -- FACTION AXIS --------------------------------------------------------
  //
  // Mod Settings has no multi-select list control, so the allow-list is one boolean per major
  // faction plus a catch-all. The keys are Affiliation_Record.EnumName() values
  // (orphans.script:4404-4448) and a compiled RTTI enum cannot be extended, so mod-added
  // factions reach only the catch-all.
  //
  // Enforcement of this group additionally requires KSTPGate.FactionAxisEnabled(). With that
  // gate off the settings are still read, because the overlay colours by policy verdict.

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Enable faction filtering")
  @runtimeProperty("ModSettings.description", "Restrict locks to the factions ticked below. On by default, with NCPD, Trauma Team, Aldecaldos and Afterlife mercs already unticked, so a fresh install does not lock onto police or medics. Works at every coprocessor tier.")
  public let factionFilterEnabled: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Engage attitudes")
  @runtimeProperty("ModSettings.description", "Which attitudes the smart link may engage. Attitude is read live from the target's AI, never cached. Entities with no attitude agent (drones, turrets, vehicles) are exempt from this check and fall through to the faction list.")
  @runtimeProperty("ModSettings.displayValues.Inherit", "INHERIT (use protocol default)")
  @runtimeProperty("ModSettings.displayValues.HostileOnly", "HOSTILE ONLY")
  @runtimeProperty("ModSettings.displayValues.HostileAndNeutral", "HOSTILE + NEUTRAL")
  @runtimeProperty("ModSettings.displayValues.Any", "ANY")
  public let attitudeMask: KSTPAttitudeChoice = KSTPAttitudeChoice.Inherit;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Allow civilians")
  @runtimeProperty("ModSettings.description", "Covers the Civilian affiliation and anything the classifier flags as a civilian or crowd NPC, whichever faction record it carries. On by default: turning it off suppresses every pedestrian in the district, which costs a large number of stat modifiers. Turn it off only to make the smart link refuse civilians outright.")
  // Defaults on: civilians are the large majority of NPCs in Night City, so denying them sets
  // the cost of the whole faction feature. See ADR 0005.
  public let allowCivilians: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Allow unlisted factions")
  @runtimeProperty("ModSettings.description", "Catch-all for every affiliation with no toggle of its own: Unaffiliated, Unknown, Classified, the minor DLC factions, and any faction added by another mod. It does not override the toggles below, so an unticked faction stays refused either way. Leave this on unless you want a hard whitelist that refuses everything not explicitly ticked.")
  public let factionUnlisted: Bool = true;

  // Corpos
  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Arasaka")
  @runtimeProperty("ModSettings.description", "")
  public let factionArasaka: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Militech")
  @runtimeProperty("ModSettings.description", "")
  public let factionMilitech: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Kang Tao")
  @runtimeProperty("ModSettings.description", "")
  public let factionKangTao: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Biotechnica")
  @runtimeProperty("ModSettings.description", "")
  public let factionBiotechnica: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "NetWatch")
  @runtimeProperty("ModSettings.description", "")
  public let factionNetWatch: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Zetatech")
  @runtimeProperty("ModSettings.description", "")
  public let factionZetatech: Bool = true;

  // Law and state
  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "NCPD")
  @runtimeProperty("ModSettings.description", "Keys on the affiliation record rather than on the game's own police test, because an NCPD-affiliated NPC does not reliably pass that test.")
  public let factionNCPD: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "NUSA")
  @runtimeProperty("ModSettings.description", "")
  public let factionNUSA: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Trauma Team")
  @runtimeProperty("ModSettings.description", "")
  public let factionTraumaTeam: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Barghest")
  @runtimeProperty("ModSettings.description", "")
  public let factionBarghest: Bool = true;

  // Gangs
  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Maelstrom")
  @runtimeProperty("ModSettings.description", "Also covers Maelstrom androids, which carry a separate affiliation record.")
  public let factionMaelstrom: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Scavengers")
  @runtimeProperty("ModSettings.description", "Also covers Scavenger androids.")
  public let factionScavengers: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "6th Street")
  @runtimeProperty("ModSettings.description", "Also covers 6th Street androids.")
  public let factionSixthStreet: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Tyger Claws")
  @runtimeProperty("ModSettings.description", "")
  public let factionTygerClaws: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Valentinos")
  @runtimeProperty("ModSettings.description", "")
  public let factionValentinos: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Voodoo Boys")
  @runtimeProperty("ModSettings.description", "")
  public let factionVoodooBoys: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Wraiths")
  @runtimeProperty("ModSettings.description", "Also covers Wraith androids.")
  public let factionWraiths: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Animals")
  @runtimeProperty("ModSettings.description", "")
  public let factionAnimals: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "The Mox")
  @runtimeProperty("ModSettings.description", "")
  public let factionTheMox: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Aldecaldos")
  @runtimeProperty("ModSettings.description", "")
  public let factionAldecaldos: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "20")
  @runtimeProperty("ModSettings.displayName", "Afterlife mercs")
  @runtimeProperty("ModSettings.description", "")
  public let factionAfterlifeMercs: Bool = false;

  // -- DEBUG ---------------------------------------------------------------
  //
  // Mod Settings groups on the rendered category string, and these labels are literal display
  // text rather than loc keys (the mod ships no .archive, so a custom key would render raw), so
  // a group label must stay character-for-character identical everywhere it appears, here and in
  // KSTPGateConfig (Core/Gate.reds). The experiment gates are declared there, not here.

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug")
  @runtimeProperty("ModSettings.category.order", "900")
  @runtimeProperty("ModSettings.displayName", "Multi-target tracking in ADS")
  @runtimeProperty("ModSettings.description", "LEAVE THIS ON INHERIT until it has been tested on your own build. Writes gamedataStatType.SmartGunTrackMultipleEntitiesInADS (orphans.script:2789). The stat exists and can be written, but nothing in the 2.31 script dump reads it, so FORCE ON may do nothing at all. INHERIT does not touch the stat, which is the safe setting and the shipped default.")
  @runtimeProperty("ModSettings.displayValues.Inherit", "INHERIT (leave vanilla alone)")
  @runtimeProperty("ModSettings.displayValues.ForceOff", "FORCE OFF")
  @runtimeProperty("ModSettings.displayValues.ForceOn", "FORCE ON")
  public let multiEntityADS: KSTPMultiEntityChoice = KSTPMultiEntityChoice.Inherit;

  // -- Derived accessors ---------------------------------------------------
  //
  // Consumers go through these rather than reading raw fields, so the master switch is honoured
  // in exactly one place.

  // The protocol id the player picked, in KSTPPolicySystem's id space.
  public func SelectedProtocolId() -> Int32 {
    return EnumInt(this.activeProtocol);
  }

  public func CustomClassAllowed(cls: KSTPTargetClass) -> Bool {
    switch cls {
      case KSTPTargetClass.Head:       return this.classHead;
      case KSTPTargetClass.Chest:      return this.classChest;
      case KSTPTargetClass.Leg:        return this.classLeg;
      case KSTPTargetClass.WeakSpot:   return this.classWeakSpot;
      case KSTPTargetClass.Mechanical: return this.classMechanical;
      case KSTPTargetClass.Breach:     return this.classBreach;
      case KSTPTargetClass.Vehicle:    return this.classVehicle;
    }
    return true;
  }

  // Master off means vanilla: every class lockable, nothing written.
  public func EffectiveAllows(p: ref<KSTPProtocol>, cls: KSTPTargetClass) -> Bool {
    if !this.masterEnabled {
      return true;
    };
    return this.CustomClassAllowed(cls);
  }

  public func EffectiveLockPolicy(p: ref<KSTPProtocol>) -> KSTPLockPolicy {
    switch this.lockPolicy {
      case KSTPLockPolicyChoice.Strict:    return KSTPLockPolicy.Strict;
      case KSTPLockPolicyChoice.Preferred: return KSTPLockPolicy.Preferred;
    }
    if IsDefined(p) {
      return p.lockPolicy;
    };
    return KSTPLockPolicy.Preferred;
  }

  public func EffectiveAttitudeMask(p: ref<KSTPProtocol>) -> KSTPAttitudeMask {
    switch this.attitudeMask {
      case KSTPAttitudeChoice.HostileOnly:       return KSTPAttitudeMask.HostileOnly;
      case KSTPAttitudeChoice.HostileAndNeutral: return KSTPAttitudeMask.HostileAndNeutral;
      case KSTPAttitudeChoice.Any:               return KSTPAttitudeMask.Any;
    }
    if IsDefined(p) {
      return p.attitudeMask;
    };
    return KSTPAttitudeMask.HostileAndNeutral;
  }

  // -1 means "leave the stat alone", matching KSTPProtocol.multiEntityADS.
  public func EffectiveMultiEntityADS(p: ref<KSTPProtocol>) -> Int32 {
    if !this.masterEnabled {
      return -1;
    };
    switch this.multiEntityADS {
      case KSTPMultiEntityChoice.ForceOff: return 0;
      case KSTPMultiEntityChoice.ForceOn:  return 1;
    }
    if IsDefined(p) {
      return p.multiEntityADS;
    };
    return -1;
  }

  // What the protocol wants. The overlay uses this so it can show the verdict even on a build
  // where the engine will not honour it.
  public func FactionFilterRequested() -> Bool {
    return this.masterEnabled && this.factionFilterEnabled;
  }

  // What will be enforced, so the settings layer never promises more than the gate allows.
  // Enforcement/Faction.reds checks the gate itself too.
  public func FactionFilterEnforced() -> Bool {
    return this.FactionFilterRequested() && KSTPGate.FactionAxisEnabled();
  }

  // Materialised allow-list for KSTPProtocol.allowedAffiliations. This class describes the filter;
  // Core/Classifier.reds decides it, folding android variants in KSTPClassifier.FoldAffiliation
  // (which also strips a generic <Faction>Android suffix, so mod-added android records fold too)
  // and returning the verdict from KSTPClassifier.Permits. Android variants are pushed beside
  // their parent here for callers that compare raw EnumName() without folding.
  //
  // An empty array is meaningful: Permits reads "no allow-list" as "no affiliation constraint", so
  // callers must guard on FactionFilterRequested() before trusting the result, as ApplyTo does.
  public func BuildAllowedAffiliations() -> array<CName> {
    let out: array<CName>;
    if this.factionArasaka        { ArrayPush(out, n"Arasaka"); };
    if this.factionMilitech       { ArrayPush(out, n"Militech"); };
    if this.factionKangTao        { ArrayPush(out, n"KangTao"); };
    if this.factionBiotechnica    { ArrayPush(out, n"Biotechnica"); };
    if this.factionNetWatch       { ArrayPush(out, n"NetWatch"); };
    if this.factionZetatech       { ArrayPush(out, n"Zetatech"); };
    if this.factionNCPD           { ArrayPush(out, n"NCPD"); };
    if this.factionNUSA           { ArrayPush(out, n"NUSA"); };
    if this.factionTraumaTeam     { ArrayPush(out, n"TraumaTeam"); };
    if this.factionBarghest       { ArrayPush(out, n"Barghest"); };
    if this.factionMaelstrom      { ArrayPush(out, n"Maelstrom"); ArrayPush(out, n"MaelstromAndroid"); };
    if this.factionScavengers     { ArrayPush(out, n"Scavengers"); ArrayPush(out, n"ScavengersAndroid"); };
    if this.factionSixthStreet    { ArrayPush(out, n"SixthStreet"); ArrayPush(out, n"SixthStreetAndroid"); };
    if this.factionTygerClaws     { ArrayPush(out, n"TygerClaws"); };
    if this.factionValentinos     { ArrayPush(out, n"Valentinos"); };
    if this.factionVoodooBoys     { ArrayPush(out, n"VoodooBoys"); };
    if this.factionWraiths        { ArrayPush(out, n"Wraiths"); ArrayPush(out, n"WraithsAndroid"); };
    if this.factionAnimals        { ArrayPush(out, n"Animals"); };
    if this.factionTheMox         { ArrayPush(out, n"TheMox"); };
    if this.factionAldecaldos     { ArrayPush(out, n"Aldecaldos"); };
    if this.factionAfterlifeMercs { ArrayPush(out, n"AfterlifeMercs"); };
    if this.allowCivilians        { ArrayPush(out, n"Civilian"); };
    return out;
  }

  // The complement: every faction with a toggle here whose toggle is off. The allow-list alone
  // cannot express this, because once it is built "unticked" and "unknown to this menu" are the
  // same absence and the unlisted catch-all would readmit the factions just switched off.
  // KSTPClassifier.Permits consults this list before the catch-all.
  //
  // n"Civilian" is excluded: civilians are refused by the allowCivilians branch in Permits, which
  // also covers NPCs the classifier flags as civilian or crowd under some other affiliation
  // record.
  public func BuildDeniedAffiliations() -> array<CName> {
    let out: array<CName>;
    if !this.factionArasaka        { ArrayPush(out, n"Arasaka"); };
    if !this.factionMilitech       { ArrayPush(out, n"Militech"); };
    if !this.factionKangTao        { ArrayPush(out, n"KangTao"); };
    if !this.factionBiotechnica    { ArrayPush(out, n"Biotechnica"); };
    if !this.factionNetWatch       { ArrayPush(out, n"NetWatch"); };
    if !this.factionZetatech       { ArrayPush(out, n"Zetatech"); };
    if !this.factionNCPD           { ArrayPush(out, n"NCPD"); };
    if !this.factionNUSA           { ArrayPush(out, n"NUSA"); };
    if !this.factionTraumaTeam     { ArrayPush(out, n"TraumaTeam"); };
    if !this.factionBarghest       { ArrayPush(out, n"Barghest"); };
    if !this.factionMaelstrom      { ArrayPush(out, n"Maelstrom"); ArrayPush(out, n"MaelstromAndroid"); };
    if !this.factionScavengers     { ArrayPush(out, n"Scavengers"); ArrayPush(out, n"ScavengersAndroid"); };
    if !this.factionSixthStreet    { ArrayPush(out, n"SixthStreet"); ArrayPush(out, n"SixthStreetAndroid"); };
    if !this.factionTygerClaws     { ArrayPush(out, n"TygerClaws"); };
    if !this.factionValentinos     { ArrayPush(out, n"Valentinos"); };
    if !this.factionVoodooBoys     { ArrayPush(out, n"VoodooBoys"); };
    if !this.factionWraiths        { ArrayPush(out, n"Wraiths"); ArrayPush(out, n"WraithsAndroid"); };
    if !this.factionAnimals        { ArrayPush(out, n"Animals"); };
    if !this.factionTheMox         { ArrayPush(out, n"TheMox"); };
    if !this.factionAldecaldos     { ArrayPush(out, n"Aldecaldos"); };
    if !this.factionAfterlifeMercs { ArrayPush(out, n"AfterlifeMercs"); };
    return out;
  }

  // Writes every settings-owned axis onto a protocol instance: the single point where the menu
  // meets the presets. The rest of the mod reads KSTPProtocol fields directly
  // (Enforcement/BodyPart.reds:267, Core/Classifier.reds:285-322).
  //
  // The caller must pass a protocol just restored from its baseline, as
  // KSTPSettingsSystem.Reconcile does, because the Inherit branches read `p` for the inherited
  // value.
  public func ApplyTo(p: ref<KSTPProtocol>) -> Void {
    if !IsDefined(p) {
      return;
    };

    if !this.masterEnabled {
      // Enforcement writes modifiers only for denied classes and for a non-negative
      // multiEntityADS, so a fully permissive protocol produces none at all.
      let i: Int32 = 0;
      while i < KSTPTargetClassCount() {
        p.SetAllows(IntEnum<KSTPTargetClass>(i), true);
        i += 1;
      };
      p.multiEntityADS = -1;
      p.factionFilterEnabled = false;
      p.allowCivilians = true;
      p.allowUnlistedAffiliations = true;
      p.attitudeMask = KSTPAttitudeMask.Any;
      ArrayClear(p.allowedAffiliations);
      ArrayClear(p.deniedAffiliations);
      return;
    };

    let j: Int32 = 0;
    while j < KSTPTargetClassCount() {
      let cls: KSTPTargetClass = IntEnum<KSTPTargetClass>(j);
      p.SetAllows(cls, this.CustomClassAllowed(cls));
      j += 1;
    };

    p.lockPolicy = this.EffectiveLockPolicy(p);
    p.multiEntityADS = this.EffectiveMultiEntityADS(p);
    p.factionFilterEnabled = this.FactionFilterRequested();

    if p.factionFilterEnabled {
      p.attitudeMask = this.EffectiveAttitudeMask(p);
      p.allowCivilians = this.allowCivilians;
      p.allowedAffiliations = this.BuildAllowedAffiliations();
      p.deniedAffiliations = this.BuildDeniedAffiliations();
      // KSTPClassifier.Permits reads this flag off the protocol, the only object enforcement and
      // the overlay ever see; without the write the allow-list is always a hard whitelist.
      p.allowUnlistedAffiliations = this.factionUnlisted;
    };
  }
}

// ---------------------------------------------------------------------------
// Baseline
// ---------------------------------------------------------------------------

// Pristine copy of a protocol as KSTPPolicySystem.EnsureProtocols() built it. Applying settings
// mutates the presets in place, so without this a setting turned back off would leave the preset
// rewritten for the rest of the session.
public class KSTPProtocolBaseline {
  public let id: Int32;
  public let allowedClasses: array<Bool>;
  public let lockPolicy: KSTPLockPolicy;
  public let attitudeMask: KSTPAttitudeMask;
  public let allowCivilians: Bool;
  public let multiEntityADS: Int32;
  public let factionFilterEnabled: Bool;
  public let allowedAffiliations: array<CName>;
  public let deniedAffiliations: array<CName>;
  public let allowUnlistedAffiliations: Bool;
}

// ---------------------------------------------------------------------------
// Change notification
// ---------------------------------------------------------------------------

// Queued on the player and on the UI system whenever Mod Settings reports a change, for
// consumers that would rather subscribe than poll KSTPSettingsSystem.GetRevision().
public class KSTPSettingsChangedEvent extends Event {}

// ---------------------------------------------------------------------------
// Menu write-back
// ---------------------------------------------------------------------------

// Pushes the live protocol id into the "Active protocol" box so the control shows what the hotkey
// has selected. This is the only code that names `ModSettings`, hence the module guard and the
// empty counterpart; an install without the plugin loses only this. See ADR 0010.
//
// Lookup walks the categories this mod registered and matches ConfigVar.GetName() against the
// field name, after auto_drive_enhanced\settings.reds:648-663. A protocol id and a
// KSTPProtocolChoice ordinal are the same number, but the box indexes its own value list, which
// need not be, so GetIndexFor supplies the translation.
@if(ModuleExists("ModSettingsModule"))
public func KSTP_WriteProtocolToMenu(id: Int32) -> Void {
  let modName: CName = n"Kiroshi Targeting Protocol";
  let categories: array<CName> = ModSettings.GetCategories(modName);
  let c: Int32 = 0;
  while c < ArraySize(categories) {
    let vars: array<ref<ConfigVar>> = ModSettings.GetVars(modName, categories[c]);
    let v: Int32 = 0;
    while v < ArraySize(vars) {
      if Equals(vars[v].GetName(), n"activeProtocol") {
        let box: ref<ModConfigVarEnum> = vars[v] as ModConfigVarEnum;
        if IsDefined(box) {
          let index: Int32 = box.GetIndexFor(id);
          // An unchanged write still costs an AcceptChanges, which persists the whole page to
          // user.ini, and the hotkey can be held down.
          if index >= 0 && index != box.GetIndex() {
            box.SetIndex(index);
            ModSettings.AcceptChanges();
          };
        };
        return;
      };
      v += 1;
    };
    c += 1;
  };
}

@if(!ModuleExists("ModSettingsModule"))
public func KSTP_WriteProtocolToMenu(id: Int32) -> Void {}

// ---------------------------------------------------------------------------
// Settings system
// ---------------------------------------------------------------------------

// Holds the live settings and hotkey copies, since the overlay reads settings every frame, and
// owns the reconciliation between the menu and the presets. Registered under the fully qualified
// RTTI name "KSTP.Core.KSTPSettingsSystem", because module-scoped classes register qualified, as
// KSTPPolicySystem does (Policy.reds:145).
public class KSTPSettingsSystem extends ScriptableSystem {

  private let m_settings: ref<KSTPSettings>;
  private let m_hotkeys: ref<KSTPHotkeys>;
  private let m_baselines: array<ref<KSTPProtocolBaseline>>;
  private let m_revision: Int32;

  // The protocol the menu showed at the last reconcile. Redscript accepts only literal constants
  // as field initialisers, so a -1 sentinel is unavailable and a default of 0 is indistinguishable
  // from AUTO; the flag separates them. Until it is set, the first reconcile must not stamp the
  // menu default over the protocol saved in the game.
  private let m_lastMenuProtocol: Int32;
  private let m_menuProtocolKnown: Bool;

  private func OnAttach() -> Void {
    this.Reload();
    this.Reconcile();
  }

  private func OnDetach() -> Void {
    this.m_settings = null;
    this.m_hotkeys = null;
    ArrayClear(this.m_baselines);
    this.m_menuProtocolKnown = false;
  }

  // Records id as the value the menu now shows and pushes it into the box. Called after the hotkey
  // has moved the protocol, so a later Reconcile does not read this write back as a player edit.
  public func SyncMenuProtocol(id: Int32) -> Void {
    KSTP_WriteProtocolToMenu(id);
    this.m_lastMenuProtocol = id;
    this.m_menuProtocolKnown = true;
    if IsDefined(this.m_settings) {
      this.m_settings.activeProtocol = IntEnum<KSTPProtocolChoice>(id);
    };
  }

  // Re-reads the menu and pushes the result through. Called when the settings menu closes; safe
  // to call at any other time, and cheap enough that a redundant call does not matter.
  public func RefreshFromMenu() -> Void {
    this.Reload();
    this.m_revision += 1;
    this.Reconcile();
    this.Broadcast();

    // Info, not Debug: every downstream count in a bug report is unreadable without the toggles
    // that produced it, and this fires once per settings-menu close.
    KSTPLog.Info(this.DescribeSettings());
  }

  // One line naming every axis the menu owns, in the order the menu presents them. Reads the live
  // settings rather than the protocol, so it reports what was requested; protocol state after
  // reconciliation is reported by the enforcement traces.
  public func DescribeSettings() -> String {
    let s: ref<KSTPSettings> = this.GetSettings();
    if !IsDefined(s) {
      return "settings: unavailable";
    };
    let classes: String = "";
    let i: Int32 = 0;
    while i < KSTPTargetClassCount() {
      let cls: KSTPTargetClass = IntEnum<KSTPTargetClass>(i);
      if s.CustomClassAllowed(cls) {
        classes += KSTPStats.ClassLabel(cls) + " ";
      };
      i += 1;
    };
    if StrLen(classes) == 0 {
      classes = "(none) ";
    };
    // ArraySize() must measure a named local: applied straight to the call result it reported 370
    // and 518 in successive sessions against a hard maximum of 25.
    let deniedList: array<CName> = s.BuildDeniedAffiliations();
    let deniedNames: String = "";
    let d: Int32 = 0;
    while d < ArraySize(deniedList) {
      deniedNames += NameToString(deniedList[d]) + " ";
      d += 1;
    };
    if StrLen(deniedNames) == 0 {
      deniedNames = "(none) ";
    };

    // Overlay visibility is not reported here: KSTPOverlayConfig sits in module KSTP.UI, which
    // already imports KSTP.Core, so naming it would close an import cycle. The hotkey trace in
    // Input/Hotkeys.reds prints it instead.
    return s"settings applied: master=\(s.masterEnabled) protocol=\(EnumInt(s.activeProtocol)) lockPolicy=\(EnumInt(s.lockPolicy)) | classes ON: \(classes)| factionFilter=\(s.factionFilterEnabled) civilians=\(s.allowCivilians) unlisted=\(s.factionUnlisted) attitudes=\(EnumInt(s.attitudeMask)) | denied(\(ArraySize(deniedList))): \(deniedNames)";
  }

  private func Reload() -> Void {
    this.m_settings = new KSTPSettings();
    this.m_hotkeys = new KSTPHotkeys();
  }

  // Restores every preset to how Policy built it, then stamps the menu on top. Idempotent, so
  // callers may fire it as often as they like.
  public func Reconcile() -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(gi);
    if !IsDefined(policy) {
      return;
    };

    let settings: ref<KSTPSettings> = this.GetSettings();
    let protocols: array<ref<KSTPProtocol>> = policy.GetAll();
    let i: Int32 = 0;
    while i < ArraySize(protocols) {
      let p: ref<KSTPProtocol> = protocols[i];
      this.RestoreBaseline(p);
      settings.ApplyTo(p);
      i += 1;
    };

    // Protocol selection is owned by KSTPPolicySystem and persisted into the save, so a menu edit
    // is honoured only when the box actually moves; see ADR 0010.
    let menuId: Int32 = settings.SelectedProtocolId();
    if this.m_menuProtocolKnown && menuId != this.m_lastMenuProtocol {
      policy.SetActive(menuId);
    };
    this.m_lastMenuProtocol = menuId;
    this.m_menuProtocolKnown = true;

    policy.OnSettingsChanged();
  }

  private func RestoreBaseline(p: ref<KSTPProtocol>) -> Void {
    let b: ref<KSTPProtocolBaseline> = this.EnsureBaseline(p);
    let i: Int32 = 0;
    while i < ArraySize(b.allowedClasses) && i < ArraySize(p.allowedClasses) {
      p.allowedClasses[i] = b.allowedClasses[i];
      i += 1;
    };
    p.lockPolicy = b.lockPolicy;
    p.attitudeMask = b.attitudeMask;
    p.allowCivilians = b.allowCivilians;
    p.multiEntityADS = b.multiEntityADS;
    p.factionFilterEnabled = b.factionFilterEnabled;
    p.allowUnlistedAffiliations = b.allowUnlistedAffiliations;
    ArrayClear(p.allowedAffiliations);
    let j: Int32 = 0;
    while j < ArraySize(b.allowedAffiliations) {
      ArrayPush(p.allowedAffiliations, b.allowedAffiliations[j]);
      j += 1;
    };
    ArrayClear(p.deniedAffiliations);
    let d: Int32 = 0;
    while d < ArraySize(b.deniedAffiliations) {
      ArrayPush(p.deniedAffiliations, b.deniedAffiliations[d]);
      d += 1;
    };
  }

  // Snapshotted the first time a protocol is seen, which is before anything here has had a chance
  // to mutate it.
  private func EnsureBaseline(p: ref<KSTPProtocol>) -> ref<KSTPProtocolBaseline> {
    let i: Int32 = 0;
    while i < ArraySize(this.m_baselines) {
      if this.m_baselines[i].id == p.id {
        return this.m_baselines[i];
      };
      i += 1;
    };

    let b: ref<KSTPProtocolBaseline> = new KSTPProtocolBaseline();
    b.id = p.id;
    let j: Int32 = 0;
    while j < ArraySize(p.allowedClasses) {
      ArrayPush(b.allowedClasses, p.allowedClasses[j]);
      j += 1;
    };
    b.lockPolicy = p.lockPolicy;
    b.attitudeMask = p.attitudeMask;
    b.allowCivilians = p.allowCivilians;
    b.multiEntityADS = p.multiEntityADS;
    b.factionFilterEnabled = p.factionFilterEnabled;
    b.allowUnlistedAffiliations = p.allowUnlistedAffiliations;
    let k: Int32 = 0;
    while k < ArraySize(p.allowedAffiliations) {
      ArrayPush(b.allowedAffiliations, p.allowedAffiliations[k]);
      k += 1;
    };
    let m: Int32 = 0;
    while m < ArraySize(p.deniedAffiliations) {
      ArrayPush(b.deniedAffiliations, p.deniedAffiliations[m]);
      m += 1;
    };
    ArrayPush(this.m_baselines, b);
    return b;
  }

  private func Broadcast() -> Void {
    let gi: GameInstance = this.GetGameInstance();
    let player: ref<PlayerPuppet> = GetPlayer(gi);
    if IsDefined(player) {
      player.QueueEvent(new KSTPSettingsChangedEvent());
    };
    let ui: ref<UISystem> = GameInstance.GetUISystem(gi);
    if IsDefined(ui) {
      ui.QueueEvent(new KSTPSettingsChangedEvent());
    };
  }

  public func GetSettings() -> ref<KSTPSettings> {
    if !IsDefined(this.m_settings) {
      this.Reload();
    };
    return this.m_settings;
  }

  public func GetHotkeys() -> ref<KSTPHotkeys> {
    if !IsDefined(this.m_hotkeys) {
      this.Reload();
    };
    return this.m_hotkeys;
  }

  // Bumped on every Mod Settings change, for per-frame consumers that would rather compare
  // an Int32 than subscribe to an event.
  public func GetRevision() -> Int32 {
    return this.m_revision;
  }

  public final static func Get(gi: GameInstance) -> ref<KSTPSettingsSystem> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"KSTP.Core.KSTPSettingsSystem") as KSTPSettingsSystem;
  }
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------

// The live settings. Safe before the system is attached (main menu, early load): the fallback
// instance has already been patched by Mod Settings with the saved values, so the answer is
// correct either way.
public func KSTP_Settings(gi: GameInstance) -> ref<KSTPSettings> {
  let sys: ref<KSTPSettingsSystem> = KSTPSettingsSystem.Get(gi);
  if IsDefined(sys) {
    return sys.GetSettings();
  };
  return new KSTPSettings();
}

public func KSTP_Hotkeys(gi: GameInstance) -> ref<KSTPHotkeys> {
  let sys: ref<KSTPSettingsSystem> = KSTPSettingsSystem.Get(gi);
  if IsDefined(sys) {
    return sys.GetHotkeys();
  };
  return new KSTPHotkeys();
}

// Re-runs the menu-to-presets reconciliation. Called from Input/Hotkeys.reds once the player puppet
// is up, because the settings system and the policy system attach independently and either order
// has to end with the presets reconciled.
public func KSTP_ReconcileSettings(gi: GameInstance) -> Void {
  let sys: ref<KSTPSettingsSystem> = KSTPSettingsSystem.Get(gi);
  if IsDefined(sys) {
    sys.Reconcile();
  };
}

// ---------------------------------------------------------------------------
// Menu-closed signal
// ---------------------------------------------------------------------------

// Mod Settings renders its page inside the pause menu, so this fires on the gesture that commits a
// change, and standing in for the framework's own change callback keeps `ModSettings` out of the
// compiled reference set (ADR 0010). @wrapMethod, so it chains with Core/Policy.reds's wrap of the
// same method and with any other mod's (Limited HUD wraps it too).
@wrapMethod(PauseMenuGameController)
protected cb func OnUninitialize() -> Bool {
  let result: Bool = wrappedMethod();
  let player: ref<GameObject> = this.GetPlayerControlledObject();
  if IsDefined(player) {
    let sys: ref<KSTPSettingsSystem> = KSTPSettingsSystem.Get(player.GetGame());
    if IsDefined(sys) {
      sys.RefreshFromMenu();
    };
  };
  return result;
}
