// Kiroshi Smart Targeting Protocol: IFF overlay.
//
// Draws one label per tracked smart-gun candidate over the vanilla crosshair target holder:
// affiliation, threat class, attitude, and the active protocol's verdict. Read-only with respect
// to the game, so Detach() restores nothing beyond its own widgets. A verdict is drawn at every
// cyberware tier, and a refusal nothing enforces is drawn REFUSE* rather than REFUSE
// (ADR 0003, ADR 0011).
//
// Data comes from the UI_ActiveWeaponData.SmartGunParams payload
// (blackboardDefinitions.script:1601; smartGunUIParameters at orphans.script:54420-54460),
// delivered by the host hooks at the bottom of this file. GameObject.IsTargetedWithSmartWeapon()
// and OnSmartGunLockEvent are not a usable substitute: that handler ignores evt.locked and
// evt.lockedOnByPlayer and flips its own cached bool on every event (gameObject.script:2623-2637).
//
// Host is CrosshairGameController_Smart_Rifl (crosshairController_Smart_Rifle.script:1), live only
// while a smart weapon's crosshair is up; CrosshairGameController_BlackwallForce extends it.
// Depends on KSTP.Core, on KSTP.Enforcement for KSTP_PushSmartGunParams, and on Mod Settings as a
// soft dependency (ADR 0010).

module KSTP.UI

import KSTP.Core.*
import KSTP.Enforcement.*

// Vertical lift, in screen units, that puts the label above the target rather than centred on it.
// A function because redscript will not fold a negated literal into a constant field initializer.
public func KSTP_LabelBaselineY() -> Float = -52.0

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

// Declared here rather than in UI/Settings.reds so the overlay runs on the compiled defaults with
// Mod Settings absent (ADR 0010); UI/Settings.reds imports this class instead of declaring a
// second copy. Display strings are literals, not LocKeys: the mod ships no .archive, so a custom
// key has nothing to resolve against and the menu renders the raw key text (ADR 0004, ADR 0008).
// ModSettings.mod must stay byte-identical to Core/Gate.reds and UI/Settings.reds, or these
// options file onto a separate menu page.

// Which corner of the vanilla smart-crosshair target holder the labels measure from.
enum KSTPOverlayAnchorMode {
  HolderTopLeft = 0,
  HolderCentered = 1,
}

// When the labels are drawn. One control with one answer, replacing three booleans; see ADR 0011.
// The old field names are absent deliberately: Mod Settings maps by field name and ignores keys
// with no matching field, so stale entries in an existing user.ini are inert.
enum KSTPOverlayVisibility {
  Always = 0,
  WhileAiming = 1,
  WhileKeyHeld = 2,
  Never = 3,
}

// Overlay settings. Mod Settings patches the class defaults, so a fresh instance carries the
// player's current values.
public class KSTPOverlayConfig {

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - IFF overlay")
  @runtimeProperty("ModSettings.category.order", "910")
  @runtimeProperty("ModSettings.displayName", "Overlay visibility")
  @runtimeProperty("ModSettings.description", "When to draw a label over every target the smart weapon is tracking: faction, threat class, attitude, and whether the active protocol permits or refuses it. ALWAYS draws whenever a smart weapon is up. ONLY WHILE AIMING draws down sights, and the overlay key still pulls it up from the hip. ONLY WITH THE OVERLAY KEY draws nothing until that key is used. NEVER removes the labels entirely. The two key options need the KSTP_Overlay binding from r6/input/kstp_inputs.xml, which requires Input Loader or REDmod.")
  @runtimeProperty("ModSettings.displayValues.Always", "ALWAYS")
  @runtimeProperty("ModSettings.displayValues.WhileAiming", "ONLY WHILE AIMING")
  @runtimeProperty("ModSettings.displayValues.WhileKeyHeld", "ONLY WITH THE OVERLAY KEY")
  @runtimeProperty("ModSettings.displayValues.Never", "NEVER")
  public let Visibility: KSTPOverlayVisibility = KSTPOverlayVisibility.Always;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - IFF overlay")
  @runtimeProperty("ModSettings.category.order", "910")
  @runtimeProperty("ModSettings.displayName", "Only label refused targets")
  @runtimeProperty("ModSettings.description", "Label only the targets the active protocol refuses. The overlay then stays quiet in a normal fight and marks the targets the protocol turns down. Refusals the installed coprocessor is too low a tier to enforce are labeled REFUSE* and are still shown.")
  public let OnlyRefused: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - IFF overlay")
  @runtimeProperty("ModSettings.category.order", "910")
  @runtimeProperty("ModSettings.displayName", "Show distance")
  @runtimeProperty("ModSettings.description", "Append the range in meters, as the smart weapon reports it.")
  public let ShowDistance: Bool = false;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - IFF overlay")
  @runtimeProperty("ModSettings.category.order", "910")
  @runtimeProperty("ModSettings.displayName", "Show lock state")
  @runtimeProperty("ModSettings.description", "Append the tracking state: TRACK, LOCKING, LOCK or BREAK.")
  public let ShowLockState: Bool = true;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - overlay layout")
  @runtimeProperty("ModSettings.category.order", "920")
  @runtimeProperty("ModSettings.displayName", "Label anchor")
  @runtimeProperty("ModSettings.description", "Which corner of the crosshair target holder the labels measure from. TOP-LEFT is correct on a standard HUD. Switch to CENTERED if labels land far from their targets.")
  @runtimeProperty("ModSettings.displayValues.HolderTopLeft", "TOP-LEFT")
  @runtimeProperty("ModSettings.displayValues.HolderCentered", "CENTERED")
  public let AnchorMode: KSTPOverlayAnchorMode = KSTPOverlayAnchorMode.HolderTopLeft;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - overlay layout")
  @runtimeProperty("ModSettings.category.order", "920")
  @runtimeProperty("ModSettings.displayName", "Horizontal offset")
  @runtimeProperty("ModSettings.step", "4.0")
  @runtimeProperty("ModSettings.min", "-400.0")
  @runtimeProperty("ModSettings.max", "400.0")
  public let OffsetX: Float = 0.0;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - overlay layout")
  @runtimeProperty("ModSettings.category.order", "920")
  @runtimeProperty("ModSettings.displayName", "Vertical offset")
  @runtimeProperty("ModSettings.step", "4.0")
  @runtimeProperty("ModSettings.min", "-400.0")
  @runtimeProperty("ModSettings.max", "400.0")
  // Delta on top of KSTP_LabelBaselineY(), which already lifts the label above the target.
  public let OffsetY: Float = 0.0;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - overlay layout")
  @runtimeProperty("ModSettings.category.order", "920")
  @runtimeProperty("ModSettings.displayName", "Font size")
  @runtimeProperty("ModSettings.step", "1")
  @runtimeProperty("ModSettings.min", "12")
  @runtimeProperty("ModSettings.max", "40")
  public let FontSize: Int32 = 20;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - overlay layout")
  @runtimeProperty("ModSettings.category.order", "920")
  @runtimeProperty("ModSettings.displayName", "Label background opacity")
  @runtimeProperty("ModSettings.step", "0.05")
  @runtimeProperty("ModSettings.min", "0.0")
  @runtimeProperty("ModSettings.max", "1.0")
  public let BackgroundOpacity: Float = 0.55;

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug - overlay layout")
  @runtimeProperty("ModSettings.category.order", "920")
  @runtimeProperty("ModSettings.displayName", "Maximum labels on screen")
  @runtimeProperty("ModSettings.step", "1")
  @runtimeProperty("ModSettings.min", "1")
  @runtimeProperty("ModSettings.max", "16")
  public let MaxLabels: Int32 = 10;
}

// Hold-to-show channel. Input/Hotkeys.reds writes this flag and the overlay only reads it, so
// neither module has to reference the other.
@addField(UI_SystemDef) public let KSTPOverlayHold: BlackboardID_Bool;

// Current visibility mode as text, for the hotkey trace in Input/Hotkeys.reds. Reads the live
// setting rather than a cached copy: the key can be pressed with no weapon drawn, when no overlay
// instance exists.
public func KSTP_OverlayVisibilityName() -> String {
  switch new KSTPOverlayConfig().Visibility {
    case KSTPOverlayVisibility.Always:       return "ALWAYS (key is not read)";
    case KSTPOverlayVisibility.WhileAiming:  return "WHILE_AIMING (key overrides from the hip)";
    case KSTPOverlayVisibility.WhileKeyHeld: return "WITH_KEY (key gates the overlay)";
    case KSTPOverlayVisibility.Never:        return "NEVER (key is not read)";
  }
  return "UNKNOWN";
}

// ---------------------------------------------------------------------------
// Presentation
// ---------------------------------------------------------------------------

enum KSTPVerdict {
  Permitted = 0,
  // Refused, and the refusal is being applied to the target.
  Refused = 1,
  // Cyberware not installed or no smart weapon in hand: the protocol is enforcing nothing.
  Offline = 2,
  // Refused, but nothing acts on the refusal: the installed coprocessor is below
  // no coprocessor is installed, or KSTPGate.FactionAxisEnabled() is off. The target still
  // classifies and colours.
  RefusedAdvisory = 3,
}

// Label text and colours. Stateless.
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

  // The trailing asterisk marks a refusal the gun will not honour. Colour carries the same
  // distinction, so the mark never has to be read to be understood.
  public static func VerdictLabel(v: KSTPVerdict) -> String {
    switch v {
      case KSTPVerdict.Permitted:       return "PERMIT";
      case KSTPVerdict.Refused:         return "REFUSE";
      case KSTPVerdict.RefusedAdvisory: return "REFUSE*";
    }
    return "OFFLINE";
  }

  // True for both refusal kinds, for callers filtering on whether a target would be refused
  // rather than on whether the refusal binds.
  public static func IsRefusal(v: KSTPVerdict) -> Bool {
    return Equals(v, KSTPVerdict.Refused) || Equals(v, KSTPVerdict.RefusedAdvisory);
  }

  // Tints the chip and the secondary line. Amber for the advisory refusal must stay readable
  // against the red of an enforced one at a glance.
  public static func VerdictColor(v: KSTPVerdict) -> HDRColor {
    switch v {
      case KSTPVerdict.Permitted:       return new HDRColor(0.29, 0.94, 0.63, 1.0);
      case KSTPVerdict.Refused:         return new HDRColor(1.00, 0.22, 0.24, 1.0);
      case KSTPVerdict.RefusedAdvisory: return new HDRColor(1.00, 0.70, 0.20, 1.0);
    }
    return new HDRColor(0.62, 0.66, 0.72, 1.0);
  }

  // Tints the affiliation line only, never the chip. Keyed on Affiliation_Record.EnumName() so
  // mod-added factions fall through to the default instead of colliding with a compiled enum
  // ordinal. Android variants are separate affiliation values and repeat the parent's colour.
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

// One reusable label widget tree. Slots are recycled across targets: Resolve() rebinds a slot to
// a different entity, Show() positions and fills it, Hide() leaves it built. Destroy() must be
// passed the same parent the slot was created under.
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

  // Resolves the entity behind the slot, cached until the slot is handed a different id. This is
  // the most expensive step per target.
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

  // Positions and fills the label. pos is the target's screen position as the smart-gun payload
  // reports it.
  public func Show(pos: Vector2, cfg: ref<KSTPOverlayConfig>, primary: String, secondary: String, verdict: KSTPVerdict, affiliation: CName) -> Void {
    // Half-scale, the coordinate math vanilla uses for its own target brackets in this holder
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

// One overlay instance per smart crosshair. Owned by the host controller, which attaches it on
// intro, drives it from OnSmartGunParams and detaches it on outro or uninitialize. Attach() is
// idempotent and Detach() must run before the holder widget dies.
public class KSTPIFFOverlay extends IScriptable {

  private let m_game: GameInstance;
  private let m_holder: wref<inkCompoundWidget>;
  private let m_container: ref<inkCanvas>;
  private let m_slots: array<ref<KSTPIFFLabel>>;

  private let m_psmBlackboard: wref<IBlackboard>;
  private let m_uiSystemBlackboard: wref<IBlackboard>;

  private let m_config: ref<KSTPOverlayConfig>;
  private let m_configTicks: Int32;
  private let m_attached: Bool;

  // Callback counter. Kept separate from m_configTicks, which Attach() resets and which reaches
  // zero only once every 60 callbacks, so the first callback of a session is always reported.
  private let m_tickCount: Int32;

  // Builds the widget tree under holder and binds the blackboards the visibility test reads. No
  // listener is registered: delivery comes from the host hooks at the bottom of this file.
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

    this.m_attached = true;

    KSTPLog.Info(s"overlay attached: \(ArraySize(this.m_slots)) label slot(s), visibility=\(KSTP_OverlayVisibilityName()), driven by the host controller's OnSmartGunParams");
  }

  // Removes every widget this overlay created. Idempotent, and nothing else needs restoring.
  public func Detach() -> Void {
    if !this.m_attached { return; }
    this.m_attached = false;

    KSTPLog.Info(s"overlay detached after \(this.m_tickCount) callback(s)");
    this.m_tickCount = 0;

    this.m_psmBlackboard = null;
    this.m_uiSystemBlackboard = null;

    this.DestroyWidgets();
    this.m_config = null;
  }

  // The container is zero-size so its origin coincides with the holder's own child origin, the
  // space vanilla's brackets measure in.
  //
  // UNVERIFIED: which corner of the target holder its bucket widgets anchor from lives in the
  // .inkwidget resource, not in script, so it cannot be read off the 2.31 dump. TopLeft is the
  // reading consistent with positive pos.X/pos.Y margins; AnchorMode exposes the alternative.
  private func BuildWidgets() -> Void {
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

  // Re-reads the settings every 60 ticks, then restyles or rebuilds the slots when a value that
  // shapes the widget tree has moved. Reading on every tick would allocate per frame.
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

  // True while the labels should be drawn. The hold flag reaches this through vanilla
  // GameObject.RegisterInputListener (gameObject.script:152) with no framework involved, so it is
  // honoured unconditionally; with no loader for r6/input/*.xml the binding never fires and the
  // ALWAYS setting is the recovery.
  private func ShouldDraw() -> Bool {
    switch this.m_config.Visibility {
      case KSTPOverlayVisibility.Never:        return false;
      case KSTPOverlayVisibility.Always:       return true;
      case KSTPOverlayVisibility.WhileKeyHeld: return this.IsHoldActive();
      case KSTPOverlayVisibility.WhileAiming:  return this.IsHoldActive() || this.IsAimingDownSights();
    }
    return true;
  }

  // Draw pass for one smart-gun payload. Called directly by the host controller's wrap below, so
  // it is a plain method rather than a `cb func`: nothing dispatches it through RTTI.
  public func OnSmartGunParams(argParams: Variant) -> Bool {
    if !this.m_attached || !IsDefined(this.m_container) { return false; }
    this.RefreshConfig();

    let draw: Bool = this.ShouldDraw();

    this.m_tickCount += 1;
    if (this.m_tickCount == 1 || this.m_tickCount % 60 == 0) && KSTPLog.DebugEnabled() {
      let smartPeek: ref<smartGunUIParameters> = FromVariant<ref<smartGunUIParameters>>(argParams);
      let count: Int32 = -1;
      if IsDefined(smartPeek) {
        count = ArraySize(smartPeek.targets);
      };
      KSTPLog.Debug(s"overlay tick #\(this.m_tickCount): visibility=\(KSTP_OverlayVisibilityName()) held=\(this.IsHoldActive()) ads=\(this.IsAimingDownSights()) draw=\(draw) gunTargets=\(count) slots=\(ArraySize(this.m_slots))");
    };

    if !draw {
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
    // Read once per tick, never per target: every KSTPGate accessor allocates a config object
    // (Core/Gate.reds:110-111).
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

  // Fills one slot from one payload entry. Returns false when the slot was left untouched, so the
  // caller reuses it for the next target.
  private func DrawTarget(slot: ref<KSTPIFFLabel>, data: smartGunUITargetParameters, protocol: ref<KSTPProtocol>, armed: Bool, axisEnforced: Bool) -> Bool {
    let target: wref<GameObject> = slot.Resolve(this.m_game, data.entityID);
    if !IsDefined(target) { return false; }

    let classification: ref<KSTPClassification> = KSTPClassifier.Classify(target);
    if !IsDefined(classification) { return false; }

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

    // Advisory refusals pass this filter: below the enforcing tier they are all it can show.
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
// ---------------------------------------------------------------------------

// Attach and detach follow the lifetime of vanilla's own SmartGunParams listener, which
// CrosshairGameController_Smart_Rifl registers and unregisters in OnPreIntro/OnPreOutro
// (crosshairController_Smart_Rifle.script:105/111).

@addField(CrosshairGameController_Smart_Rifl)
public let kstpOverlay: ref<KSTPIFFOverlay>;

@wrapMethod(CrosshairGameController_Smart_Rifl)
protected cb func OnPreIntro() -> Bool {
  wrappedMethod();
  KSTP_EnsureOverlay(this, true);
}

// The delivery point for the whole mod. The host registers UI_ActiveWeaponData.SmartGunParams at
// crosshairController_Smart_Rifle.script:67 and handles it at :91, so KSTP takes that delivery
// rather than registering its own: a RegisterDelayedListener* from outside an ink game controller
// never fires on 2.31, because the delayed queue is drained by the UI traversal that services
// those controllers, and every call site in the dump sits on one.
// CrosshairGameController_BlackwallForce calls super.OnSmartGunParams
// (crosshairController_Blackwall.script:11-15), so wrapping the base covers that crosshair too.
// Attaches the overlay to a crosshair controller, replacing any instance already on it when
// `rebuild` is set. Safe to call repeatedly: without `rebuild` an existing overlay is left alone.
//
// Attaching from OnPreIntro alone loses the overlay across a save load. The crosshair intro plays
// when a smart weapon is raised, and a load restores the player with one already in hand, so the
// intro never runs and no attach ever fires. Measured: a load at 23:28:45 left the weapon armed
// with no attach for sixteen seconds, until a holster and redraw forced the intro.
public func KSTP_EnsureOverlay(controller: ref<CrosshairGameController_Smart_Rifl>, rebuild: Bool) -> Void {
  if !IsDefined(controller) {
    return;
  };
  if IsDefined(controller.kstpOverlay) {
    if !rebuild {
      return;
    };
    controller.kstpOverlay.Detach();
    controller.kstpOverlay = null;
  };
  let holder: wref<inkCompoundWidget> = inkWidgetRef.Get(controller.m_targetHolder) as inkCompoundWidget;
  if IsDefined(holder) && IsDefined(controller.m_playerPuppet) {
    controller.kstpOverlay = new KSTPIFFOverlay();
    controller.kstpOverlay.Attach(controller.GetGame(), controller.m_playerPuppet, holder);
  };
}

@wrapMethod(CrosshairGameController_Smart_Rifl)
protected cb func OnSmartGunParams(argParams: Variant) -> Bool {
  let handled: Bool = wrappedMethod(argParams);

  // The payload arriving is proof the controller is live and its widget tree is up, so this is
  // the recovery point for the save-load case where OnPreIntro never ran.
  KSTP_EnsureOverlay(this, false);

  if IsDefined(this.kstpOverlay) {
    this.kstpOverlay.OnSmartGunParams(argParams);
  };

  // params.targets carries entries while their lock is still forming, and a time-to-lock modifier
  // can only prevent a lock that has not completed (ADR 0003).
  KSTP_PushSmartGunParams(this.GetGame(), argParams);

  return handled;
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
// controller torn down without an outro (HUD rebuild, save load) would leave the overlay bound to
// a dead widget tree. OnUninitialize is declared on the base
// (crosshairBaseControllers.script:68), so the hook lives there and downcasts.
@wrapMethod(gameuiCrosshairBaseGameController)
protected cb func OnUninitialize() -> Bool {
  let smartCrosshair: ref<CrosshairGameController_Smart_Rifl> = this as CrosshairGameController_Smart_Rifl;
  if IsDefined(smartCrosshair) && IsDefined(smartCrosshair.kstpOverlay) {
    smartCrosshair.kstpOverlay.Detach();
    smartCrosshair.kstpOverlay = null;
  };

  wrappedMethod();
}
