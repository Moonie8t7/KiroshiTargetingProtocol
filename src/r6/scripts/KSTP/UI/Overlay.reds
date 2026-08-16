// Kiroshi Smart Targeting Protocol: IFF overlay.
//
// Reads the live smart-gun lock list from the UI_ActiveWeaponData.SmartGunParams blackboard
// (blackboardDefinitions.script:1601, payload smartGunUIParameters at
// orphans.script:54420-54460) and draws a compact IFF label over every tracked candidate:
// affiliation, threat class, attitude, and the active protocol's permit or refuse verdict.
//
// The verdict is drawn at every cyberware tier. A refusal the coprocessor is too low a tier to
// enforce, or one the gate has turned off, is marked REFUSE* in amber against the red REFUSE of
// one Enforcement/Faction.reds is applying, so the label never promises a denial the gun will
// not honor while still showing what the protocol would refuse.
//
// This module is read-only with respect to the game. It never touches targeting state, never
// applies a stat modifier and never mutates a world entity, so teardown has nothing to restore
// beyond its own widgets, which Detach() removes symmetrically.
//
// Host: CrosshairGameController_Smart_Rifl (crosshairController_Smart_Rifle.script:1). That
// controller exists only while a smart weapon's crosshair is up, and
// CrosshairGameController_BlackwallForce extends it, so hooking it covers both. The
// registration and read pattern follows hud_panzer.script:130-132 and
// crosshairController_Smart_Rifle.script:107/112.
//
// GameObject.IsTargetedWithSmartWeapon() and OnSmartGunLockEvent are not a usable source of
// truth here. The handler ignores evt.locked and evt.lockedOnByPlayer and flips its own cached
// bool on every event (gameObject.script:2623-2637), so the flag it maintains does not track
// the real lock state. The blackboard payload is the authority.

module KSTP.UI

import KSTP.Core.*

// Default vertical lift, in screen units, that puts the IFF label above the target rather than
// centered on it. Written as a function because redscript will not fold a negated literal into
// a constant field initializer. KSTPOverlayConfig.OffsetY is the player-facing delta on top.
public func KSTP_LabelBaselineY() -> Float = -52.0

// ---------------------------------------------------------------------------
// Settings
//
// Declared here rather than in UI/Settings.reds so the overlay is self-contained and runs on
// the compiled defaults when the Mod Settings framework is absent; the runtimeProperty
// annotations are inert without it. UI/Settings.reds imports this class rather than declaring
// a second copy, which would show duplicated entries in the menu.
//
// Display strings are literals, not LocKeys. The mod ships no .archive and has no WolvenKit
// pack step, so a custom key has nothing to resolve against and Mod Settings renders the raw
// key text in the menu. Literals are what the shipping corpus uses when it has no localization
// archive of its own; CP77Mods\Limited HUD passes 'E3 Compass' and 'FPS Counter' straight
// through. The ModSettings.mod value must stay byte-identical to the one in Core/Gate.reds and
// UI/Settings.reds, or the plugin files these options onto a second, separate menu page.
// ---------------------------------------------------------------------------

// Which corner of the vanilla smart-crosshair target holder the labels measure from.
enum KSTPOverlayAnchorMode {
  HolderTopLeft = 0,
  HolderCentered = 1,
}

public class KSTPOverlayConfig {

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Show the IFF overlay")
  @runtimeProperty("ModSettings.description", "Draws a label over every target the smart weapon is tracking: faction, threat class, attitude, and whether the active protocol permits or refuses it. Off removes the labels entirely.")
  public let Enabled: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Only while aiming")
  @runtimeProperty("ModSettings.description", "Show the labels only while aiming down sights. Holding the overlay key overrides this and shows them from the hip as well.")
  public let OnlyWhileADS: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Only while the overlay key is held")
  @runtimeProperty("ModSettings.description", "Hide the labels until the overlay key is pressed (hold or toggle, set in the keybindings group). Requires the KSTP_Overlay binding from r6/input/kstp_inputs.xml, which needs Input Loader or REDmod. If the key does nothing on your install, turn this back off.")
  public let OnlyWhileHeld: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Only label refused targets")
  @runtimeProperty("ModSettings.description", "Label only the targets the active protocol refuses. The overlay then stays quiet in a normal fight and marks the targets the protocol turns down. Refusals the installed coprocessor is too low a tier to enforce are labeled REFUSE* and are still shown.")
  public let OnlyRefused: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Show distance")
  @runtimeProperty("ModSettings.description", "Append the range in meters, as the smart weapon reports it.")
  public let ShowDistance: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay")
  @runtimeProperty("ModSettings.category.order", "10")
  @runtimeProperty("ModSettings.displayName", "Show lock state")
  @runtimeProperty("ModSettings.description", "Append the tracking state: TRACK, LOCKING, LOCK or BREAK.")
  public let ShowLockState: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay - layout")
  @runtimeProperty("ModSettings.category.order", "11")
  @runtimeProperty("ModSettings.displayName", "Label anchor")
  @runtimeProperty("ModSettings.description", "Which corner of the crosshair target holder the labels measure from. TOP-LEFT is correct on a standard HUD. Switch to CENTERED if labels land far from their targets.")
  @runtimeProperty("ModSettings.displayValues.HolderTopLeft", "TOP-LEFT")
  @runtimeProperty("ModSettings.displayValues.HolderCentered", "CENTERED")
  public let AnchorMode: KSTPOverlayAnchorMode = KSTPOverlayAnchorMode.HolderTopLeft;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay - layout")
  @runtimeProperty("ModSettings.category.order", "11")
  @runtimeProperty("ModSettings.displayName", "Horizontal offset")
  @runtimeProperty("ModSettings.step", "4.0")
  @runtimeProperty("ModSettings.min", "-400.0")
  @runtimeProperty("ModSettings.max", "400.0")
  public let OffsetX: Float = 0.0;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay - layout")
  @runtimeProperty("ModSettings.category.order", "11")
  @runtimeProperty("ModSettings.displayName", "Vertical offset")
  @runtimeProperty("ModSettings.step", "4.0")
  @runtimeProperty("ModSettings.min", "-400.0")
  @runtimeProperty("ModSettings.max", "400.0")
  // Offset from the label's default position, which already sits above the target
  // (see KSTP_LabelBaselineY). Redscript rejects a negated literal in a constant
  // initializer, so the baseline lift is applied at the use site rather than here.
  public let OffsetY: Float = 0.0;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay - layout")
  @runtimeProperty("ModSettings.category.order", "11")
  @runtimeProperty("ModSettings.displayName", "Font size")
  @runtimeProperty("ModSettings.step", "1")
  @runtimeProperty("ModSettings.min", "12")
  @runtimeProperty("ModSettings.max", "40")
  public let FontSize: Int32 = 20;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay - layout")
  @runtimeProperty("ModSettings.category.order", "11")
  @runtimeProperty("ModSettings.displayName", "Label background opacity")
  @runtimeProperty("ModSettings.step", "0.05")
  @runtimeProperty("ModSettings.min", "0.0")
  @runtimeProperty("ModSettings.max", "1.0")
  public let BackgroundOpacity: Float = 0.55;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "IFF overlay - layout")
  @runtimeProperty("ModSettings.category.order", "11")
  @runtimeProperty("ModSettings.displayName", "Maximum labels on screen")
  @runtimeProperty("ModSettings.step", "1")
  @runtimeProperty("ModSettings.min", "1")
  @runtimeProperty("ModSettings.max", "16")
  public let MaxLabels: Int32 = 10;
}

// Hold-to-show channel. Input/Hotkeys.reds writes this flag and the overlay only reads it, so
// neither module has to reference the other. Same idiom as Limited HUD's global toggle flag.
@addField(UI_SystemDef) public let KSTPOverlayHold: BlackboardID_Bool;

// ---------------------------------------------------------------------------
// Presentation
// ---------------------------------------------------------------------------

enum KSTPVerdict {
  Permitted = 0,
  // The protocol refuses this target and the refusal is being applied to it.
  Refused = 1,
  // Cyberware not installed or no smart weapon in hand. The protocol is not enforcing
  // anything, so reporting a refusal would be wrong.
  Offline = 2,
  // The protocol refuses this target but nothing acts on the refusal: the installed
  // coprocessor is below KSTP_FactionAxisMinTier(), or KSTPGate.FactionAxisEnabled() is off.
  // Enforcement/Faction.reds applies nothing in either state, so the label has to say so
  // rather than promise a denial the gun will not honor. The target still classifies and
  // colors, which is what makes the tier worth buying.
  RefusedAdvisory = 3,
}

public class KSTPIFFStyle {

  public static func ThreatLabel(t: KSTPThreatClass) -> String {
    switch t {
      case KSTPThreatClass.Civilian:  return "CIVILIAN";
      case KSTPThreatClass.Police:    return "NCPD";
      case KSTPThreatClass.Ganger:    return "GANGER";
      case KSTPThreatClass.Netrunner: return "NETRUNNER";
      case KSTPThreatClass.Drone:     return "DRONE";
      case KSTPThreatClass.Mech:      return "MECH";
      case KSTPThreatClass.Turret:    return "TURRET";
      case KSTPThreatClass.Elite:     return "ELITE";
      case KSTPThreatClass.Boss:      return "BOSS";
      case KSTPThreatClass.MaxTac:    return "MAXTAC";
    }
    return "UNKNOWN";
  }

  public static func AttitudeLabel(known: Bool, a: EAIAttitude) -> String {
    if !known { return "NO IFF"; }
    switch a {
      case EAIAttitude.AIA_Friendly: return "FRIENDLY";
      case EAIAttitude.AIA_Hostile:  return "HOSTILE";
    }
    return "NEUTRAL";
  }

  public static func LockLabel(state: gamesmartGunTargetState, isLocked: Bool) -> String {
    if isLocked { return "LOCK"; }
    switch state {
      case gamesmartGunTargetState.Locked:     return "LOCK";
      case gamesmartGunTargetState.Locking:    return "LOCKING";
      case gamesmartGunTargetState.Unlocking:  return "BREAK";
      case gamesmartGunTargetState.Targetable: return "TRACK";
    }
    return "SEEN";
  }

  // The trailing asterisk on an advisory refusal is the whole distinction between a denial
  // the gun will honor and one the protocol would make if the coprocessor could enforce it.
  // Color carries the same split, so the mark never has to be read to be understood.
  public static func VerdictLabel(v: KSTPVerdict) -> String {
    switch v {
      case KSTPVerdict.Permitted:       return "PERMIT";
      case KSTPVerdict.Refused:         return "REFUSE";
      case KSTPVerdict.RefusedAdvisory: return "REFUSE*";
    }
    return "OFFLINE";
  }

  // Both refusal kinds, for callers that filter on "would this target be refused" rather than
  // on whether the refusal binds.
  public static func IsRefusal(v: KSTPVerdict) -> Bool {
    return Equals(v, KSTPVerdict.Refused) || Equals(v, KSTPVerdict.RefusedAdvisory);
  }

  // Verdict drives the chip and the secondary line. The player must be able to read it without
  // parsing any text, so it is the loudest signal on the label. Amber for the advisory refusal
  // keeps it distinct from the red of an enforced one at a glance and from across a firefight.
  public static func VerdictColor(v: KSTPVerdict) -> HDRColor {
    switch v {
      case KSTPVerdict.Permitted:       return new HDRColor(0.29, 0.94, 0.63, 1.0);
      case KSTPVerdict.Refused:         return new HDRColor(1.00, 0.22, 0.24, 1.0);
      case KSTPVerdict.RefusedAdvisory: return new HDRColor(1.00, 0.70, 0.20, 1.0);
    }
    return new HDRColor(0.62, 0.66, 0.72, 1.0);
  }

  // Faction is the secondary signal and tints the affiliation line only, never the chip.
  // Keyed on Affiliation_Record.EnumName() so mod-added factions fall through to the default
  // instead of colliding with a compiled enum ordinal. Android variants share the parent
  // faction's color; MaelstromAndroid is a separate affiliation value from Maelstrom.
  public static func FactionColor(affiliation: CName) -> HDRColor {
    switch affiliation {
      case n"Arasaka":            return new HDRColor(0.94, 0.27, 0.31, 1.0);
      case n"Militech":           return new HDRColor(0.36, 0.70, 0.46, 1.0);
      case n"KangTao":            return new HDRColor(0.98, 0.62, 0.24, 1.0);
      case n"NetWatch":           return new HDRColor(0.45, 0.71, 0.98, 1.0);
      case n"Zetatech":           return new HDRColor(0.55, 0.78, 0.86, 1.0);
      case n"Biotechnica":        return new HDRColor(0.60, 0.84, 0.44, 1.0);
      case n"NCPD":               return new HDRColor(0.30, 0.60, 1.00, 1.0);
      case n"TraumaTeam":         return new HDRColor(1.00, 0.85, 0.30, 1.0);
      case n"Maelstrom":          return new HDRColor(0.86, 0.24, 0.20, 1.0);
      case n"MaelstromAndroid":   return new HDRColor(0.86, 0.24, 0.20, 1.0);
      case n"Scavengers":         return new HDRColor(0.68, 0.60, 0.42, 1.0);
      case n"ScavengersAndroid":  return new HDRColor(0.68, 0.60, 0.42, 1.0);
      case n"SixthStreet":        return new HDRColor(0.44, 0.56, 0.98, 1.0);
      case n"SixthStreetAndroid": return new HDRColor(0.44, 0.56, 0.98, 1.0);
      case n"Wraiths":            return new HDRColor(0.74, 0.52, 0.86, 1.0);
      case n"WraithsAndroid":     return new HDRColor(0.74, 0.52, 0.86, 1.0);
      case n"TygerClaws":         return new HDRColor(0.98, 0.36, 0.72, 1.0);
      case n"Valentinos":         return new HDRColor(0.98, 0.45, 0.35, 1.0);
      case n"VoodooBoys":         return new HDRColor(0.52, 0.90, 0.78, 1.0);
      case n"Animals":            return new HDRColor(0.94, 0.72, 0.34, 1.0);
      case n"TheMox":             return new HDRColor(0.90, 0.44, 0.86, 1.0);
      case n"Aldecaldos":         return new HDRColor(0.92, 0.66, 0.30, 1.0);
      case n"Barghest":           return new HDRColor(0.70, 0.74, 0.40, 1.0);
      case n"Civilian":           return new HDRColor(0.80, 0.84, 0.88, 1.0);
    }
    return new HDRColor(0.78, 0.82, 0.86, 1.0);
  }

  public static func FontPath() -> String = "base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily"
}

// ---------------------------------------------------------------------------
// One label
// ---------------------------------------------------------------------------

public class KSTPIFFLabel extends IScriptable {

  private let m_root: ref<inkCanvas>;
  private let m_background: ref<inkRectangle>;
  private let m_chip: ref<inkRectangle>;
  private let m_primary: ref<inkText>;
  private let m_secondary: ref<inkText>;

  // Cached so a per-frame blackboard tick does not re-issue identical widget writes.
  private let m_boundTo: EntityID;
  private let m_target: wref<GameObject>;
  private let m_lastPrimary: String;
  private let m_lastSecondary: String;

  public static func Create(parent: ref<inkCompoundWidget>, cfg: ref<KSTPOverlayConfig>) -> ref<KSTPIFFLabel> {
    let label: ref<KSTPIFFLabel> = new KSTPIFFLabel();

    let root: ref<inkCanvas> = new inkCanvas();
    root.SetName(n"KSTPIFFLabel");
    root.SetAnchor(inkEAnchor.TopLeft);
    root.SetAnchorPoint(0.5, 0.5);
    root.SetFitToContent(true);
    root.SetInteractive(false);
    root.SetVisible(false);
    root.Reparent(parent);

    let background: ref<inkRectangle> = new inkRectangle();
    background.SetAnchor(inkEAnchor.Fill);
    background.SetHAlign(inkEHorizontalAlign.Fill);
    background.SetVAlign(inkEVerticalAlign.Fill);
    background.SetTintColor(new HDRColor(0.02, 0.03, 0.05, 1.0));
    background.SetOpacity(cfg.BackgroundOpacity);
    background.Reparent(root);

    let row: ref<inkHorizontalPanel> = new inkHorizontalPanel();
    row.SetFitToContent(true);
    row.SetMargin(new inkMargin(6.0, 4.0, 10.0, 4.0));
    row.SetChildMargin(new inkMargin(0.0, 0.0, 8.0, 0.0));
    row.Reparent(root);

    let chip: ref<inkRectangle> = new inkRectangle();
    chip.SetSize(6.0, 10.0);
    chip.SetVAlign(inkEVerticalAlign.Fill);
    chip.Reparent(row);

    let column: ref<inkVerticalPanel> = new inkVerticalPanel();
    column.SetFitToContent(true);
    column.Reparent(row);

    let primary: ref<inkText> = new inkText();
    primary.SetName(n"KSTPIFFPrimary");
    primary.SetFontFamily(KSTPIFFStyle.FontPath());
    primary.SetFontStyle(n"Medium");
    primary.SetFontSize(cfg.FontSize);
    primary.SetLetterCase(textLetterCase.UpperCase);
    primary.SetHorizontalAlignment(textHorizontalAlignment.Left);
    primary.SetVerticalAlignment(textVerticalAlignment.Center);
    primary.SetFitToContent(true);
    primary.Reparent(column);

    let secondary: ref<inkText> = new inkText();
    secondary.SetName(n"KSTPIFFSecondary");
    secondary.SetFontFamily(KSTPIFFStyle.FontPath());
    secondary.SetFontStyle(n"Regular");
    secondary.SetFontSize(Max(10, cfg.FontSize - 4));
    secondary.SetLetterCase(textLetterCase.UpperCase);
    secondary.SetHorizontalAlignment(textHorizontalAlignment.Left);
    secondary.SetVerticalAlignment(textVerticalAlignment.Center);
    secondary.SetFitToContent(true);
    secondary.Reparent(column);

    label.m_root = root;
    label.m_background = background;
    label.m_chip = chip;
    label.m_primary = primary;
    label.m_secondary = secondary;
    return label;
  }

  public func ApplyStyle(cfg: ref<KSTPOverlayConfig>) -> Void {
    this.m_background.SetOpacity(cfg.BackgroundOpacity);
    this.m_primary.SetFontSize(cfg.FontSize);
    this.m_secondary.SetFontSize(Max(10, cfg.FontSize - 4));
  }

  // Resolving an EntityID to a GameObject is the most expensive step per target, so the result
  // is cached until the slot is handed a different entity.
  public func Resolve(game: GameInstance, id: EntityID) -> wref<GameObject> {
    if this.m_boundTo == id && IsDefined(this.m_target) {
      return this.m_target;
    };
    this.m_boundTo = id;
    this.m_target = null;
    if EntityID.IsDefined(id) {
      this.m_target = GameInstance.FindEntityByID(game, id) as GameObject;
    };
    return this.m_target;
  }

  public func Show(pos: Vector2, cfg: ref<KSTPOverlayConfig>, primary: String, secondary: String, verdict: KSTPVerdict, affiliation: CName) -> Void {
    // Same coordinate math vanilla uses for its own target brackets in this holder
    // (crosshairController_Smart_Rifle.script:266, hud_panzer.script:326).
    this.m_root.SetMargin(new inkMargin(pos.X * 0.50 + cfg.OffsetX, pos.Y * 0.50 + KSTP_LabelBaselineY() + cfg.OffsetY, 0.0, 0.0));

    if !Equals(this.m_lastPrimary, primary) {
      this.m_primary.SetText(primary);
      this.m_lastPrimary = primary;
    };
    if !Equals(this.m_lastSecondary, secondary) {
      this.m_secondary.SetText(secondary);
      this.m_lastSecondary = secondary;
    };

    let verdictColor: HDRColor = KSTPIFFStyle.VerdictColor(verdict);
    this.m_chip.SetTintColor(verdictColor);
    this.m_secondary.SetTintColor(verdictColor);
    this.m_primary.SetTintColor(KSTPIFFStyle.FactionColor(affiliation));
    this.m_root.SetVisible(true);
  }

  public func Hide() -> Void {
    if this.m_root.IsVisible() {
      this.m_root.SetVisible(false);
    };
  }

  public func Destroy(parent: ref<inkCompoundWidget>) -> Void {
    if IsDefined(parent) && IsDefined(this.m_root) {
      parent.RemoveChild(this.m_root);
    };
    this.m_root = null;
    this.m_background = null;
    this.m_chip = null;
    this.m_primary = null;
    this.m_secondary = null;
    this.m_target = null;
  }
}

// ---------------------------------------------------------------------------
// The overlay
// ---------------------------------------------------------------------------

public class KSTPIFFOverlay extends IScriptable {

  private let m_game: GameInstance;
  private let m_holder: wref<inkCompoundWidget>;
  private let m_container: ref<inkCanvas>;
  private let m_slots: array<ref<KSTPIFFLabel>>;

  private let m_weaponBlackboard: wref<IBlackboard>;
  private let m_weaponListener: ref<CallbackHandle>;
  private let m_psmBlackboard: wref<IBlackboard>;
  private let m_uiSystemBlackboard: wref<IBlackboard>;

  private let m_config: ref<KSTPOverlayConfig>;
  private let m_configTicks: Int32;
  private let m_attached: Bool;

  public func Attach(game: GameInstance, player: wref<GameObject>, holder: wref<inkCompoundWidget>) -> Void {
    if this.m_attached { return; }
    if !IsDefined(holder) || !IsDefined(player) { return; }

    this.m_game = game;
    this.m_holder = holder;
    this.m_config = new KSTPOverlayConfig();
    this.m_configTicks = 0;

    let bbSystem: ref<BlackboardSystem> = GameInstance.GetBlackboardSystem(game);
    this.m_psmBlackboard = bbSystem.GetLocalInstanced(player.GetEntityID(), GetAllBlackboardDefs().PlayerStateMachine);
    this.m_uiSystemBlackboard = bbSystem.Get(GetAllBlackboardDefs().UI_System);

    this.BuildWidgets();

    this.m_weaponBlackboard = bbSystem.Get(GetAllBlackboardDefs().UI_ActiveWeaponData);
    if IsDefined(this.m_weaponBlackboard) {
      this.m_weaponListener = this.m_weaponBlackboard.RegisterDelayedListenerVariant(GetAllBlackboardDefs().UI_ActiveWeaponData.SmartGunParams, this, n"OnKSTPSmartGunParams");
    };
    this.m_attached = true;
  }

  public func Detach() -> Void {
    if !this.m_attached { return; }
    this.m_attached = false;

    if IsDefined(this.m_weaponBlackboard) && IsDefined(this.m_weaponListener) {
      this.m_weaponBlackboard.UnregisterDelayedListener(GetAllBlackboardDefs().UI_ActiveWeaponData.SmartGunParams, this.m_weaponListener);
    };
    this.m_weaponListener = null;
    this.m_weaponBlackboard = null;
    this.m_psmBlackboard = null;
    this.m_uiSystemBlackboard = null;

    this.DestroyWidgets();
    this.m_config = null;
  }

  private func BuildWidgets() -> Void {
    // Zero-size canvas so its origin coincides with the holder's own child origin; every label
    // below then measures in the same space vanilla's brackets do.
    //
    // UNVERIFIED: which corner of the target holder vanilla's bucket widgets anchor from lives
    // in the .inkwidget resource, not in script, so it cannot be read off the 2.31 dump.
    // TopLeft is the reading consistent with positive pos.X/pos.Y margins. AnchorMode lets the
    // player flip it to Centered from Mod Settings if labels land half a screen away.
    let container: ref<inkCanvas> = new inkCanvas();
    container.SetName(n"KSTPIFFContainer");
    container.SetSize(0.0, 0.0);
    container.SetFitToContent(false);
    container.SetInteractive(false);
    container.SetMargin(new inkMargin(0.0, 0.0, 0.0, 0.0));
    if Equals(this.m_config.AnchorMode, KSTPOverlayAnchorMode.HolderCentered) {
      container.SetAnchor(inkEAnchor.Centered);
      container.SetAnchorPoint(0.5, 0.5);
    } else {
      container.SetAnchor(inkEAnchor.TopLeft);
      container.SetAnchorPoint(0.0, 0.0);
    };
    container.Reparent(this.m_holder);
    this.m_container = container;

    let count: Int32 = Clamp(this.m_config.MaxLabels, 1, 16);
    let i: Int32 = 0;
    while i < count {
      ArrayPush(this.m_slots, KSTPIFFLabel.Create(container, this.m_config));
      i += 1;
    };
  }

  private func DestroyWidgets() -> Void {
    let i: Int32 = 0;
    while i < ArraySize(this.m_slots) {
      this.m_slots[i].Destroy(this.m_container);
      i += 1;
    };
    ArrayClear(this.m_slots);

    if IsDefined(this.m_container) {
      this.m_container.RemoveAllChildren();
      if IsDefined(this.m_holder) {
        this.m_holder.RemoveChild(this.m_container);
      };
    };
    this.m_container = null;
    this.m_holder = null;
  }

  private func HideAll() -> Void {
    let i: Int32 = 0;
    while i < ArraySize(this.m_slots) {
      this.m_slots[i].Hide();
      i += 1;
    };
  }

  // Mod Settings patches the class defaults, so a fresh instance carries the current values.
  // Re-reading on every blackboard tick would allocate per frame; once every 60 ticks is
  // enough for a settings menu round-trip.
  private func RefreshConfig() -> Void {
    this.m_configTicks += 1;
    if this.m_configTicks < 60 { return; }
    this.m_configTicks = 0;

    let fresh: ref<KSTPOverlayConfig> = new KSTPOverlayConfig();
    let restyle: Bool = fresh.FontSize != this.m_config.FontSize || fresh.BackgroundOpacity != this.m_config.BackgroundOpacity;
    let rebuild: Bool = NotEquals(fresh.AnchorMode, this.m_config.AnchorMode) || fresh.MaxLabels != this.m_config.MaxLabels;
    this.m_config = fresh;

    if rebuild {
      let holder: wref<inkCompoundWidget> = this.m_holder;
      this.DestroyWidgets();
      this.m_holder = holder;
      this.BuildWidgets();
      return;
    };
    if restyle {
      let i: Int32 = 0;
      while i < ArraySize(this.m_slots) {
        this.m_slots[i].ApplyStyle(this.m_config);
        i += 1;
      };
    };
  }

  private func IsHoldActive() -> Bool {
    if !IsDefined(this.m_uiSystemBlackboard) { return false; }
    return this.m_uiSystemBlackboard.GetBool(GetAllBlackboardDefs().UI_System.KSTPOverlayHold);
  }

  private func IsAimingDownSights() -> Bool {
    if !IsDefined(this.m_psmBlackboard) { return false; }
    let state: gamePSMCrosshairStates = IntEnum<gamePSMCrosshairStates>(this.m_psmBlackboard.GetInt(GetAllBlackboardDefs().PlayerStateMachine.Crosshair));
    return Equals(state, gamePSMCrosshairStates.Aim);
  }

  private func ShouldDraw() -> Bool {
    if !this.m_config.Enabled { return false; }
    let held: Bool = this.IsHoldActive();
    // The hold flag is raised by Input/Hotkeys.reds through vanilla
    // GameObject.RegisterInputListener (gameObject.script:152), with no framework involved, so
    // it is honored unconditionally. Without a loader for r6/input/*.xml the binding never
    // fires, which leaves the player with a missing keybind rather than a missing capability.
    // The recovery is the one every other hold-to-show option offers: turn this setting off.
    if this.m_config.OnlyWhileHeld && !held { return false; }
    // Hold overrides the ADS restriction. A player asking for the overlay explicitly gets it
    // from the hip as well.
    if this.m_config.OnlyWhileADS && !held && !this.IsAimingDownSights() { return false; }
    return true;
  }

  protected cb func OnKSTPSmartGunParams(argParams: Variant) -> Bool {
    if !this.m_attached || !IsDefined(this.m_container) { return false; }
    this.RefreshConfig();

    if !this.ShouldDraw() {
      this.HideAll();
      return false;
    };

    let smartData: ref<smartGunUIParameters> = FromVariant<ref<smartGunUIParameters>>(argParams);
    if !IsDefined(smartData) {
      this.HideAll();
      return false;
    };

    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(this.m_game);
    let protocol: ref<KSTPProtocol>;
    let armed: Bool = false;
    // Whether a refusal reported below reaches the NPC. Enforcement/Faction.reds suppresses
    // only while both halves hold: the gate says the mechanism works on this build, the
    // installed tier says the coprocessor enforces the axis. Read once per tick, never per
    // target: every KSTPGate accessor allocates a config object (Core/Gate.reds:110-111).
    let axisEnforced: Bool = false;
    if IsDefined(policy) {
      protocol = policy.GetActive();
      armed = policy.IsArmed();
      axisEnforced = KSTPGate.FactionAxisEnabled() && policy.FactionAxisAvailable();
    };

    let targets: array<smartGunUITargetParameters> = smartData.targets;
    let slotCount: Int32 = ArraySize(this.m_slots);
    let used: Int32 = 0;
    let i: Int32 = 0;

    while i < ArraySize(targets) && used < slotCount {
      if this.DrawTarget(this.m_slots[used], targets[i], protocol, armed, axisEnforced) {
        used += 1;
      };
      i += 1;
    };

    while used < slotCount {
      this.m_slots[used].Hide();
      used += 1;
    };
    return false;
  }

  private func DrawTarget(slot: ref<KSTPIFFLabel>, data: smartGunUITargetParameters, protocol: ref<KSTPProtocol>, armed: Bool, axisEnforced: Bool) -> Bool {
    let target: wref<GameObject> = slot.Resolve(this.m_game, data.entityID);
    if !IsDefined(target) { return false; }

    let classification: ref<KSTPClassification> = KSTPClassifier.Classify(target);
    if !IsDefined(classification) { return false; }

    // Classification runs at every tier. The verdict is the protocol's answer, and
    // axisEnforced only decides which of the two refusal labels states it, so a player below
    // KSTP_FactionAxisMinTier() sees exactly which targets the tier would refuse.
    let verdict: KSTPVerdict = KSTPVerdict.Offline;
    if armed && IsDefined(protocol) {
      if KSTPClassifier.Permits(protocol, classification) {
        verdict = KSTPVerdict.Permitted;
      } else {
        if axisEnforced {
          verdict = KSTPVerdict.Refused;
        } else {
          verdict = KSTPVerdict.RefusedAdvisory;
        };
      };
    };

    // Advisory refusals count here, or the filter would empty the overlay on the tiers where
    // seeing the refusals is the only thing the feature can do.
    if this.m_config.OnlyRefused && !KSTPIFFStyle.IsRefusal(verdict) { return false; }

    let primary: String = classification.affiliationLabel;
    if StrLen(primary) == 0 {
      primary = NameToString(classification.affiliation);
    };
    if StrLen(primary) == 0 {
      primary = "UNKNOWN";
    };

    let secondary: String = KSTPIFFStyle.ThreatLabel(classification.threat)
      + "  " + KSTPIFFStyle.AttitudeLabel(classification.attitudeKnown, classification.attitude)
      + "  " + KSTPIFFStyle.VerdictLabel(verdict);
    if this.m_config.ShowLockState {
      secondary += "  " + KSTPIFFStyle.LockLabel(data.state, data.isLocked);
    };
    if this.m_config.ShowDistance {
      secondary += "  " + ToString(RoundF(data.distance)) + "M";
    };

    slot.Show(data.pos, this.m_config, primary, secondary, verdict, classification.affiliation);
    return true;
  }
}

// ---------------------------------------------------------------------------
// Host hooks
//
// CrosshairGameController_Smart_Rifl declares OnPreIntro/OnPreOutro itself
// (crosshairController_Smart_Rifle.script:105/111), which is where vanilla registers and
// unregisters its own SmartGunParams listener, so the overlay attaches and detaches there too.
// ---------------------------------------------------------------------------

@addField(CrosshairGameController_Smart_Rifl)
public let kstpOverlay: ref<KSTPIFFOverlay>;

@wrapMethod(CrosshairGameController_Smart_Rifl)
protected cb func OnPreIntro() -> Bool {
  wrappedMethod();

  if IsDefined(this.kstpOverlay) {
    this.kstpOverlay.Detach();
    this.kstpOverlay = null;
  };

  let holder: wref<inkCompoundWidget> = inkWidgetRef.Get(this.m_targetHolder) as inkCompoundWidget;
  if IsDefined(holder) && IsDefined(this.m_playerPuppet) {
    this.kstpOverlay = new KSTPIFFOverlay();
    this.kstpOverlay.Attach(this.GetGame(), this.m_playerPuppet, holder);
  };
}

@wrapMethod(CrosshairGameController_Smart_Rifl)
protected cb func OnPreOutro() -> Bool {
  if IsDefined(this.kstpOverlay) {
    this.kstpOverlay.Detach();
    this.kstpOverlay = null;
  };

  wrappedMethod();
}

// Safety net. Vanilla unregisters its own SmartGunParams listener in OnPreOutro only, so a
// controller torn down without an outro (HUD rebuild, save load) would leave the overlay's
// blackboard callback registered against a dead widget tree. OnUninitialize is declared on the
// base (crosshairBaseControllers.script:68), so the hook lives there and downcasts.
@wrapMethod(gameuiCrosshairBaseGameController)
protected cb func OnUninitialize() -> Bool {
  let smartCrosshair: ref<CrosshairGameController_Smart_Rifl> = this as CrosshairGameController_Smart_Rifl;
  if IsDefined(smartCrosshair) && IsDefined(smartCrosshair.kstpOverlay) {
    smartCrosshair.kstpOverlay.Detach();
    smartCrosshair.kstpOverlay = null;
  };

  wrappedMethod();
}
