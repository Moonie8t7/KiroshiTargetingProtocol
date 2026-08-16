// Kiroshi Smart Targeting Protocol: Mod Settings integration.
//
// Framework: jackhumbert's "Mod Settings" (red4ext\plugins\mod_settings). Its contract is
// reflective. Declare a plain script class whose fields carry @runtimeProperty annotations and
// the plugin walks RTTI to build the menu page and to patch the class defaults with whatever
// the player saved, so `new KSTPSettings()` yields the current values. Pattern taken from the
// reference corpus:
//   CP77Mods\Limited HUD\r6\scripts\LHUD\config.reds                  (field annotations)
//   CP77Mods\Custom Map Markers\...\config.reds + common\Colors.reds  (module-scoped enum as
//                                                                      an enum setting)
//
// Why there is no ModSettings.RegisterListenerToModifications call here. `ModSettings` is a
// native class registered by a RED4ext plugin, not a redscript module, so
// `@if(ModuleExists("ModSettingsModule"))` is permanently false and would compile the whole
// integration out for every player. The symbol is also absent from r6/cache/final.redscripts,
// so naming it at all makes Mod Settings a hard requirement: with the plugin missing the
// reference is unresolved and the player's entire redscript load order fails to compile. Parts
// of the corpus accept that and paper over the error with a redsUserHints message (Wannabe
// Edgerunner, Limited Fast Travel). The hard rules in docs/CONTRIBUTING.md forbid it, so KSTP
// takes the other road:
//
//   * the @runtimeProperty annotations are inert metadata. They cost nothing, and with the
//     plugin absent they are ignored and the compiled defaults stay in force;
//   * nothing in this mod names the `ModSettings` class, so KSTP compiles and plays with the
//     plugin missing;
//   * in place of the framework's change callback, refresh is driven off the
//     settings-menu-closed signal: the PauseMenuGameController.OnUninitialize wrap at the
//     bottom of this file, which is the corpus's own standard signal, used by Limited HUD
//     common.reds:396-400 and by Core/Policy.reds. The Mod Settings page lives inside the
//     pause menu, so closing it is the same gesture that applies the change.
//
// Ownership. Two other modules declare their own Mod Settings classes and this file duplicates
// neither of them, which would show every entry twice in the menu:
//   * the three experiment gates belong to KSTPGateConfig in Core/Gate.reds, read here through
//     KSTPGate and never re-declared;
//   * every overlay and HUD option belongs to KSTPOverlayConfig in UI/Overlay.reds, which asks
//     in its own header not to be mirrored here. The one exception is the hold-versus-toggle
//     behavior of the overlay hotkey, which is input behavior and lives on KSTPHotkeys next to
//     the key it modifies.
//
// Module placement: this file sits at UI/Settings.reds but declares `module KSTP.Core`.
// Core/Gate.reds, Core/Policy.reds and Enforcement/* all need settings and all already sit in
// or import KSTP.Core; making them depend on a UI module to read a bool would invert the
// layering.

module KSTP.Core

// ---------------------------------------------------------------------------
// Settings-only enums
//
// These enums exist for the menu. The gameplay types live in Types.reds and are not redefined
// here. Where a setting can defer to the active protocol's own value the enum carries an
// explicit `Inherit` member rather than overloading a sentinel.
// ---------------------------------------------------------------------------

// Ordinals are KSTPPolicySystem's protocol ids, assigned in Core/Policy.reds where the
// presets are composed.
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
//
// Split into its own class the way LimitedHudHotkeys is: the `overridableUI` attribute in
// r6/input/kstp_inputs.xml resolves against these field names, so the names here and the
// names in the XML must stay in lockstep.
// ---------------------------------------------------------------------------

public class KSTPHotkeys {

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "UI-Settings-KeyBindings")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Cycle targeting protocol")
  @runtimeProperty("ModSettings.description", "UI-Settings-Bind")
  // Must match the button id in src/r6/input/kstp_inputs.xml. Every letter key IK_A..IK_Z is
  // claimed by r6/config/inputUserMappings.xml on a stock install, so the defaults are the
  // bracket keys, which are unbound there. Both carry overridableUI in the XML and are
  // rebindable from the Mod Settings keybindings group.
  public let kstpCycleProtocolKey: EInputKey = EInputKey.IK_LeftBracket;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "UI-Settings-KeyBindings")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Show IFF overlay")
  @runtimeProperty("ModSettings.description", "UI-Settings-Bind")
  public let kstpOverlayKey: EInputKey = EInputKey.IK_RightBracket;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "UI-Settings-KeyBindings")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Overlay key is hold-to-show")
  @runtimeProperty("ModSettings.description", "On: the overlay key raises the hold flag only while the key is held down. Off: the key toggles the flag. Either way the flag matters only when the overlay's 'Only while the overlay key is held' option is on.")
  public let kstpOverlayHoldMode: Bool = true;
}

// ---------------------------------------------------------------------------
// Main settings page
// ---------------------------------------------------------------------------

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
  @runtimeProperty("ModSettings.description", "AUTO is vanilla. PRECISION biases toward heads and weak spots, CRIPPLE takes limbs only, ANTI-MACHINE takes drones and vehicles, ORGANIC skips machines, SURGICAL takes weak spots only. The live value is saved with the game and can also be cycled with the hotkey, so this box pushes a change only when it is moved. Cycling in-game survives an edit to any other setting.")
  @runtimeProperty("ModSettings.displayValues.Auto", "AUTO")
  @runtimeProperty("ModSettings.displayValues.Precision", "PRECISION")
  @runtimeProperty("ModSettings.displayValues.Cripple", "CRIPPLE")
  @runtimeProperty("ModSettings.displayValues.AntiMachine", "ANTI-MACHINE")
  @runtimeProperty("ModSettings.displayValues.Organic", "ORGANIC")
  @runtimeProperty("ModSettings.displayValues.Surgical", "SURGICAL")
  public let activeProtocol: KSTPProtocolChoice = KSTPProtocolChoice.Auto;

  // -- TARGET CLASSES ------------------------------------------------------
  //
  // Mod Settings is a static menu: it cannot show a different set of toggles per protocol.
  // These seven are therefore an override layer rather than a per-protocol editor. Off (the
  // default) means the selected preset's own mask is used and the toggles are ignored.

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Override the preset's class mask")
  @runtimeProperty("ModSettings.description", "Off: the selected protocol decides which body-part classes may be locked and the seven toggles below do nothing. On: those seven toggles replace the mask of whichever protocol is selected. Turning this back off restores the presets as shipped.")
  public let overrideClassMask: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Lock HEAD")
  @runtimeProperty("ModSettings.description", "Head components. Requires the class-mask override above.")
  public let classHead: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Lock CHEST")
  @runtimeProperty("ModSettings.description", "Torso components, the vanilla default class. Turning this off under STRICT makes most humanoids much harder to lock at all.")
  public let classChest: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Lock LIMBS")
  @runtimeProperty("ModSettings.description", "Leg and arm components. Vanilla grants this class through the Kiroshi optics fragment cyberware.")
  public let classLeg: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Lock WEAKSPOT")
  @runtimeProperty("ModSettings.description", "Explicit weak points: fuel tanks, exposed cores, cyberware mounts.")
  public let classWeakSpot: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Lock MECHANICAL")
  @runtimeProperty("ModSettings.description", "Drones, turrets and mechs.")
  public let classMechanical: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Lock BREACH")
  @runtimeProperty("ModSettings.description", "Breach points on armoured targets.")
  public let classBreach: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Lock VEHICLE")
  @runtimeProperty("ModSettings.description", "Vehicle components.")
  public let classVehicle: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Target classes")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Lock policy")
  @runtimeProperty("ModSettings.description", "STRICT turns denied classes off outright, so the reticle never acquires them. PREFERRED leaves them lockable but inflates their time-to-lock, so a permitted class wins the race for the same target. INHERIT uses whatever the selected protocol ships with. This applies whether or not the class-mask override above is on.")
  @runtimeProperty("ModSettings.displayValues.Inherit", "INHERIT (use protocol default)")
  @runtimeProperty("ModSettings.displayValues.Strict", "STRICT")
  @runtimeProperty("ModSettings.displayValues.Preferred", "PREFERRED")
  public let lockPolicy: KSTPLockPolicyChoice = KSTPLockPolicyChoice.Inherit;

  // -- FACTION AXIS --------------------------------------------------------
  //
  // Mod Settings has no multi-select list control, so the allow-list degrades to one boolean
  // per major faction plus a catch-all for everything not listed. That catch-all also covers
  // mod-added factions, which cannot appear here at all: the keys are
  // Affiliation_Record.EnumName() values and a compiled RTTI enum cannot be extended (values
  // checked against orphans.script:4404-4448).
  //
  // Enforcement of this group additionally requires KSTPGate.FactionAxisEnabled(), which
  // records the E-STAT experiment result. With that gate off the settings are still read,
  // because the overlay colors by policy verdict and the player should be able to see what a
  // protocol would refuse before the engine is proven to honor it.

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Enable faction filtering")
  @runtimeProperty("ModSettings.description", "Restrict locks to the factions ticked below. Until the E-STAT gate in the experiments group is on, this changes only how the overlay colors targets and nothing is suppressed.")
  public let factionFilterEnabled: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Engage attitudes")
  @runtimeProperty("ModSettings.description", "Which attitudes the smart link may engage. Attitude is read live from the target's AI, never cached. Entities with no attitude agent (drones, turrets, vehicles) are exempt from this check and fall through to the faction list.")
  @runtimeProperty("ModSettings.displayValues.Inherit", "INHERIT (use protocol default)")
  @runtimeProperty("ModSettings.displayValues.HostileOnly", "HOSTILE ONLY")
  @runtimeProperty("ModSettings.displayValues.HostileAndNeutral", "HOSTILE + NEUTRAL")
  @runtimeProperty("ModSettings.displayValues.Any", "ANY")
  public let attitudeMask: KSTPAttitudeChoice = KSTPAttitudeChoice.Inherit;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Allow civilians")
  @runtimeProperty("ModSettings.description", "Covers the Civilian affiliation and anything the classifier flags as a civilian or crowd NPC, whichever faction record it carries. On by default: turning it off suppresses every pedestrian in the district, which costs a large number of stat modifiers. Turn it off only to make the smart link refuse civilians outright.")
  // Defaults on. With this off, enabling faction filtering denies every civilian and crowd NPC
  // in the world: on protocol AUTO that is every live NPC around the player, around 700 stat
  // modifiers, from unticking a single gang. Civilians are the large majority of NPCs in Night
  // City, so this flag sets the cost of the whole feature. Refusing civilians is a legitimate
  // goal, so it stays available, but as an opt-in rather than a side effect of turning the
  // faction filter on.
  public let allowCivilians: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Allow unlisted factions")
  @runtimeProperty("ModSettings.description", "Catch-all for every affiliation with no toggle of its own: Unaffiliated, Unknown, Classified, the minor DLC factions, and any faction added by another mod. It does not override the toggles below, so an unticked faction stays refused either way. Leave this on unless you want a hard whitelist that refuses everything not explicitly ticked.")
  public let factionUnlisted: Bool = true;

  // Corpos
  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Arasaka")
  @runtimeProperty("ModSettings.description", "")
  public let factionArasaka: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Militech")
  @runtimeProperty("ModSettings.description", "")
  public let factionMilitech: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Kang Tao")
  @runtimeProperty("ModSettings.description", "")
  public let factionKangTao: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Biotechnica")
  @runtimeProperty("ModSettings.description", "")
  public let factionBiotechnica: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "NetWatch")
  @runtimeProperty("ModSettings.description", "")
  public let factionNetWatch: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Zetatech")
  @runtimeProperty("ModSettings.description", "")
  public let factionZetatech: Bool = true;

  // Law and state
  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "NCPD")
  @runtimeProperty("ModSettings.description", "Keys on the affiliation record rather than on the game's own police test, because an NCPD-affiliated NPC does not reliably pass that test.")
  public let factionNCPD: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "NUSA")
  @runtimeProperty("ModSettings.description", "")
  public let factionNUSA: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Trauma Team")
  @runtimeProperty("ModSettings.description", "")
  public let factionTraumaTeam: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Barghest")
  @runtimeProperty("ModSettings.description", "")
  public let factionBarghest: Bool = true;

  // Gangs
  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Maelstrom")
  @runtimeProperty("ModSettings.description", "Also covers Maelstrom androids, which carry a separate affiliation record.")
  public let factionMaelstrom: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Scavengers")
  @runtimeProperty("ModSettings.description", "Also covers Scavenger androids.")
  public let factionScavengers: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "6th Street")
  @runtimeProperty("ModSettings.description", "Also covers 6th Street androids.")
  public let factionSixthStreet: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Tyger Claws")
  @runtimeProperty("ModSettings.description", "")
  public let factionTygerClaws: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Valentinos")
  @runtimeProperty("ModSettings.description", "")
  public let factionValentinos: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Voodoo Boys")
  @runtimeProperty("ModSettings.description", "")
  public let factionVoodooBoys: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Wraiths")
  @runtimeProperty("ModSettings.description", "Also covers Wraith androids.")
  public let factionWraiths: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Animals")
  @runtimeProperty("ModSettings.description", "")
  public let factionAnimals: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "The Mox")
  @runtimeProperty("ModSettings.description", "")
  public let factionTheMox: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Aldecaldos")
  @runtimeProperty("ModSettings.description", "")
  public let factionAldecaldos: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Faction filter")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Afterlife mercs")
  @runtimeProperty("ModSettings.description", "")
  public let factionAfterlifeMercs: Bool = false;

  // -- EXPERIMENTAL --------------------------------------------------------
  //
  // Same category string as KSTPGateConfig in Core/Gate.reds so this lands in the same labeled
  // group as the three experiment gates rather than in a group of its own. Mod Settings groups
  // on the rendered string, and both sides are literal display text rather than a loc key
  // (this mod ships no .archive, so a custom key would render raw), so the two strings must
  // stay character-for-character identical. The gates themselves are declared there, not here.

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug")
  @runtimeProperty("ModSettings.category.order", "900")
  @runtimeProperty("ModSettings.displayName", "Multi-target tracking in ADS")
  @runtimeProperty("ModSettings.description", "LEAVE THIS ON INHERIT until it has been tested on your own build. Writes gamedataStatType.SmartGunTrackMultipleEntitiesInADS (orphans.script:2789). The stat exists and can be written, but nothing in the 2.31 script dump reads it, so FORCE ON may do nothing at all. INHERIT does not touch the stat, which is the safe setting and the shipped default.")
  @runtimeProperty("ModSettings.displayValues.Inherit", "INHERIT (leave vanilla alone)")
  @runtimeProperty("ModSettings.displayValues.ForceOff", "FORCE OFF")
  @runtimeProperty("ModSettings.displayValues.ForceOn", "FORCE ON")
  public let multiEntityADS: KSTPMultiEntityChoice = KSTPMultiEntityChoice.Inherit;

  // -----------------------------------------------------------------------
  // Derived accessors
  //
  // Consumers should go through these rather than reading raw fields, so the master switch
  // and the override layer are honored in exactly one place.
  // -----------------------------------------------------------------------

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

  // Master off means vanilla: everything lockable, nothing written.
  public func EffectiveAllows(p: ref<KSTPProtocol>, cls: KSTPTargetClass) -> Bool {
    if !this.masterEnabled {
      return true;
    };
    if this.overrideClassMask {
      return this.CustomClassAllowed(cls);
    };
    if !IsDefined(p) {
      return true;
    };
    return p.Allows(cls);
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

  // What the protocol wants. The overlay uses this so it can show the verdict even on a
  // build where the engine will not honor it.
  public func FactionFilterRequested() -> Bool {
    return this.masterEnabled && this.factionFilterEnabled;
  }

  // What will be enforced. Enforcement/Faction.reds checks the gate itself too;
  // this is here so the settings layer never promises more than the gate allows.
  public func FactionFilterEnforced() -> Bool {
    return this.FactionFilterRequested() && KSTPGate.FactionAxisEnabled();
  }

  // Affiliation folding and the per-affiliation verdict do not live here. Core/Classifier.reds
  // owns both:
  //   * android-variant folding is KSTPClassifier.FoldAffiliation, which also strips a generic
  //     <Faction>Android suffix so mod-added android records fold too;
  //   * the "is this affiliation allowed" verdict is KSTPClassifier.Permits, which is the path
  //     enforcement and the overlay both go through.
  // This class describes the filter (BuildAllowedAffiliations plus the allowUnlisted and
  // allowCivilians flags) and hands it to a KSTPProtocol. Deciding it is Permits's job, and
  // there is exactly one of those.

  // Materialized allow-list for KSTPProtocol.allowedAffiliations. Android variants are pushed
  // alongside their parent so a consumer comparing raw EnumName() without folding still
  // matches. KSTPClassifier.Permits handles both forms; this covers callers that do not.
  //
  // An empty array is meaningful: KSTPClassifier.Permits treats "no allow-list" as "no
  // affiliation constraint", so an all-off list must not silently mean all-on. Guard on
  // FactionFilterRequested() before trusting the result, which ApplyTo does.
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

  // The mirror image: every faction that has a toggle here and whose toggle is off. The
  // allow-list alone cannot express this. Once it is built, "Arasaka is unticked" and "Arasaka
  // is a faction this menu has never heard of" are the same absence, so the unlisted catch-all
  // (on by default) would readmit exactly the factions the player just switched off.
  // KSTPClassifier.Permits consults this list before the catch-all.
  //
  // n"Civilian" is excluded: civilians are refused by the allowCivilians branch in Permits,
  // which also covers NPCs the classifier flags as civilian or crowd while carrying some other
  // affiliation record.
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

  // Writes every settings-owned axis onto a protocol instance. The rest of the mod reads
  // KSTPProtocol fields directly (Enforcement/BodyPart.reds:267, Core/Classifier.reds:285-322),
  // so this is the single point where the menu meets the presets.
  //
  // Must be called on a protocol that has just been restored from its baseline, which
  // KSTPSettingsSystem.Reconcile does, because the Inherit branches read `p` for the value
  // they are inheriting.
  public func ApplyTo(p: ref<KSTPProtocol>) -> Void {
    if !IsDefined(p) {
      return;
    };

    if !this.masterEnabled {
      // Flatten to vanilla. Enforcement writes modifiers only for denied classes and for a
      // non-negative multiEntityADS, so a fully permissive protocol produces no modifiers at
      // all, which is what "off" has to mean.
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

    if this.overrideClassMask {
      let j: Int32 = 0;
      while j < KSTPTargetClassCount() {
        let cls: KSTPTargetClass = IntEnum<KSTPTargetClass>(j);
        p.SetAllows(cls, this.CustomClassAllowed(cls));
        j += 1;
      };
    };

    p.lockPolicy = this.EffectiveLockPolicy(p);
    p.multiEntityADS = this.EffectiveMultiEntityADS(p);
    p.factionFilterEnabled = this.FactionFilterRequested();

    if p.factionFilterEnabled {
      p.attitudeMask = this.EffectiveAttitudeMask(p);
      p.allowCivilians = this.allowCivilians;
      p.allowedAffiliations = this.BuildAllowedAffiliations();
      p.deniedAffiliations = this.BuildDeniedAffiliations();
      // Without this the allow-list is always a hard whitelist and the "Allow unlisted
      // factions" toggle does nothing. KSTPClassifier.Permits reads the flag off the protocol,
      // which is the only object enforcement and the overlay ever see.
      p.allowUnlistedAffiliations = this.factionUnlisted;
    };
  }
}

// ---------------------------------------------------------------------------
// Baseline
//
// The presets are built once per session by KSTPPolicySystem.EnsureProtocols(). Applying an
// override mutates those objects in place, so a pristine copy has to be kept or turning an
// override back off would leave the preset permanently rewritten.
// ---------------------------------------------------------------------------

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
// Settings system
//
// Holds the live copy (the overlay reads settings every frame, and `new` is cheap but not
// free), and owns the reconciliation between the menu and the presets. Registered under the
// RTTI name "KSTP.Core.KSTPSettingsSystem" because module-scoped classes register fully
// qualified, the same as KSTPPolicySystem (Policy.reds:145).
// ---------------------------------------------------------------------------

public class KSTPSettingsSystem extends ScriptableSystem {

  private let m_settings: ref<KSTPSettings>;
  private let m_hotkeys: ref<KSTPHotkeys>;
  private let m_baselines: array<ref<KSTPProtocolBaseline>>;
  private let m_revision: Int32;

  // The protocol the menu showed at the last reconcile. A `Known` flag rather than a -1
  // sentinel because redscript accepts only literal constants as field initializers, and a
  // field default of 0 would be indistinguishable from AUTO. Until the flag is set, the first
  // reconcile must not stamp the menu default over the protocol saved in the game; after that
  // a push happens only when the menu value moves, so cycling with the hotkey is never undone
  // by an unrelated settings edit.
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

  // Re-read the menu and push the result through. Called when the settings menu closes; safe
  // to call at any other time, and cheap enough that a redundant call does not matter.
  public func RefreshFromMenu() -> Void {
    this.Reload();
    this.m_revision += 1;
    this.Reconcile();
    this.Broadcast();
  }

  private func Reload() -> Void {
    this.m_settings = new KSTPSettings();
    this.m_hotkeys = new KSTPHotkeys();
  }

  // Restore every preset to how Policy built it, then stamp the menu on top. Idempotent, so
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

    // Protocol selection is owned by KSTPPolicySystem and persisted into the save, so the
    // menu is a write-only control: it pushes on an actual edit and never mirrors back.
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

  // Snapshotted the first time a protocol is seen, which is before anything here has had a
  // chance to mutate it.
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
// Free-function accessors
// ---------------------------------------------------------------------------

// Read the live settings. Safe before the system is attached (main menu, early load): falls
// back to a fresh instance, which Mod Settings has already patched with the saved values, so
// the answer is correct either way.
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

// Re-run the menu-to-presets reconciliation. Called from Input/Hotkeys.reds once the player
// puppet is up, because the settings system and the policy system attach independently and
// either order has to end with the presets reconciled.
public func KSTP_ReconcileSettings(gi: GameInstance) -> Void {
  let sys: ref<KSTPSettingsSystem> = KSTPSettingsSystem.Get(gi);
  if IsDefined(sys) {
    sys.Reconcile();
  };
}

// ---------------------------------------------------------------------------
// Settings-menu-closed signal
//
// Mod Settings renders its page inside the pause menu, so this fires on the gesture that
// commits a change. Standing in for the framework's own change callback keeps `ModSettings`
// out of the compiled reference set; see the note at the top of this file.
//
// @wrapMethod, so this chains with Core/Policy.reds's wrap of the same method and with any
// other mod's (Limited HUD wraps it too).
// ---------------------------------------------------------------------------

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
