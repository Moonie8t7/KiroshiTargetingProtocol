// Kiroshi Smart Targeting Protocol: hotkeys.
//
// Two input actions, declared in src/r6/input/kstp_inputs.xml, whose `overridableUI` attribute
// resolves against the EInputKey fields on KSTPHotkeys in UI/Settings.reds and so exposes both
// keys for rebinding through Mod Settings. Bracket defaults: r6/config/inputUserMappings.xml
// claims every IK_A..IK_Z on a stock install, IK_K as OpenCraftingMenu_Button in this same
// Exploration context.
//
//   KSTP_CycleProtocol  advance to the next targeting protocol, default IK_LeftBracket
//   KSTP_Overlay        raise the IFF overlay's hold flag, default IK_RightBracket
//
// Delivery requires a loader for r6/input/*.xml (Input Loader RED4ext plugin, or REDmod); without
// one the bindings never fire, the listener is inert and no error is logged. The listener is not
// gated on Codeware: ListenerAction and ListenerActionConsumer (orphans.script:31981-32025) and
// GameObject.RegisterInputListener / UnregisterInputListener (gameObject.script:152-156) are
// base-game natives; pattern follows CP77Mods\Limited HUD\...\core\listeners.reds:7-31.
//
// Overlay visibility modes: ADR 0011. Mod Settings write-back: ADR 0010.

module KSTP.Input

import KSTP.Core.*
// KSTP_OverlayVisibilityName() only. KSTP.UI does not import KSTP.Input, so this adds no cycle.
import KSTP.UI.*

// Names the two input edges kstp_inputs.xml subscribes to; any other edge is reported raw.
public func KSTP_InputTypeName(t: gameinputActionType) -> String {
  switch t {
    case gameinputActionType.BUTTON_PRESSED:  return "PRESSED";
    case gameinputActionType.BUTTON_RELEASED: return "RELEASED";
  }
  return "OTHER(" + ToString(EnumInt(t)) + ")";
}

// Compile-time probe for Codeware. Enforcement/Faction.reds uses it for the spawn hook and
// UI/Localization.reds for the display names; UI/Overlay.reds builds its widgets from base ink
// types and needs nothing from it.
// @if(ModuleExists(...)) is resolved by the compiler, so exactly one body is compiled and the
// result is a constant. Guard pattern follows CP77Mods\Limited HUD\r6\scripts\LHUD\utils.reds:7-16.
@if(ModuleExists("Codeware"))
public func KSTP_HasCodeware() -> Bool {
  return true;
}

@if(!ModuleExists("Codeware"))
public func KSTP_HasCodeware() -> Bool {
  return false;
}

// Writes the overlay hold flag. UI_SystemDef.KSTPOverlayHold is declared by UI/Overlay.reds and
// read there in IsHoldActive(); the blackboard is the channel because the hotkey and the overlay
// have separate lifetimes. No-op when the blackboard is unavailable.
public func KSTP_SetOverlayHold(gi: GameInstance, value: Bool) -> Void {
  let defs: ref<UI_SystemDef> = GetAllBlackboardDefs().UI_System;
  let bb: ref<IBlackboard> = GameInstance.GetBlackboardSystem(gi).Get(defs);
  if !IsDefined(bb) {
    return;
  };
  bb.SetBool(defs.KSTPOverlayHold, value, true);
}

// Current state of the overlay hold flag; false when the blackboard is unavailable.
public func KSTP_IsOverlayHeld(gi: GameInstance) -> Bool {
  let defs: ref<UI_SystemDef> = GetAllBlackboardDefs().UI_System;
  let bb: ref<IBlackboard> = GameInstance.GetBlackboardSystem(gi).Get(defs);
  if !IsDefined(bb) {
    return false;
  };
  return bb.GetBool(defs.KSTPOverlayHold);
}

// Handler for the two KSTP actions. The caller registers it per action name and must call
// SetPlayer() before the first callback; OnAction never consumes the input.
public class KSTPInputListener {

  private let m_player: wref<PlayerPuppet>;

  public func SetPlayer(player: ref<PlayerPuppet>) -> Void {
    this.m_player = player;
  }

  protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
    let player: ref<PlayerPuppet> = this.m_player;
    if !IsDefined(player) {
      return false;
    };

    let gi: GameInstance = player.GetGame();
    let actionType: gameinputActionType = ListenerAction.GetType(action);

    if ListenerAction.IsAction(action, n"KSTP_CycleProtocol") {
      // Cycling is deliberately not gated on masterEnabled.
      if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
        this.CycleProtocol(gi);
      };
      return false;
    };

    if ListenerAction.IsAction(action, n"KSTP_Overlay") {
      let holdMode: Bool = KSTP_Hotkeys(gi).kstpOverlayHoldMode;
      let before: Bool = KSTP_IsOverlayHeld(gi);

      if holdMode {
        // kstp_inputs.xml declares no <hold> element, so the flag tracks the physical key.
        if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
          KSTP_SetOverlayHold(gi, true);
        } else {
          if Equals(actionType, gameinputActionType.BUTTON_RELEASED) {
            KSTP_SetOverlayHold(gi, false);
          };
        };
      } else {
        if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
          KSTP_SetOverlayHold(gi, !before);
        };
      };

      // Info, not Debug: the presence of this line separates a dead binding from a live key whose
      // flag nothing reads, which is the case under visibility ALWAYS and NEVER.
      KSTPLog.Info(s"hotkey KSTP_Overlay: \(KSTP_InputTypeName(actionType)) holdMode=\(holdMode) hold \(before) -> \(KSTP_IsOverlayHeld(gi)), overlay visibility=\(KSTP_OverlayVisibilityName())");
      return false;
    };

    return false;
  }

  private func CycleProtocol(gi: GameInstance) -> Void {
    let policy: ref<KSTPPolicySystem> = KSTPPolicySystem.Get(gi);
    if !IsDefined(policy) {
      return;
    };
    policy.CycleNext();

    let active: ref<KSTPProtocol> = policy.GetActive();
    if !IsDefined(active) {
      return;
    };

    // The menu box otherwise keeps reporting whatever it last wrote; no-op without the Mod
    // Settings plugin (ADR 0010).
    let settings: ref<KSTPSettingsSystem> = KSTPSettingsSystem.Get(gi);
    if IsDefined(settings) {
      settings.SyncMenuProtocol(active.id);
    };

    this.ShowProtocolMessage(gi, active.displayName, policy.IsArmed(), KSTP_Settings(gi).masterEnabled);
  }

  // On-screen confirmation, stating when the new protocol will not bite. Blackboard write pattern
  // follows CP77Mods\Custom Map Markers\...\CustomMarkerSystem.reds:246-258.
  private func ShowProtocolMessage(gi: GameInstance, name: String, armed: Bool, enabled: Bool) -> Void {
    let defs: ref<UI_NotificationsDef> = GetAllBlackboardDefs().UI_Notifications;
    let bb: ref<IBlackboard> = GameInstance.GetBlackboardSystem(gi).Get(defs);
    if !IsDefined(bb) {
      return;
    };

    let text: String = "TARGETING PROTOCOL: " + name;
    if !enabled {
      text = text + "  (mod disabled)";
    } else {
      if !armed {
        text = text + "  (inactive: no smart weapon)";
      };
    };

    let msg: SimpleScreenMessage;
    msg.isShown = true;
    msg.message = text;
    msg.duration = 2.0;
    bb.SetVariant(defs.OnscreenMessage, ToVariant(msg), true);
  }
}

// Listener lifetime follows the player puppet, after
// CP77Mods\Immersive Timeskip\...\PlayerPuppet-wrapped.reds:4-18. Registering per action name
// rather than globally keeps OnAction off the hot path for unrelated input.
@addField(PlayerPuppet)
private let kstpInputListener: ref<KSTPInputListener>;

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
  wrappedMethod();

  this.kstpInputListener = new KSTPInputListener();
  this.kstpInputListener.SetPlayer(this);
  this.RegisterInputListener(this.kstpInputListener, n"KSTP_CycleProtocol");
  this.RegisterInputListener(this.kstpInputListener, n"KSTP_Overlay");

  // RegisterInputListener always succeeds; delivery depends on r6/input/kstp_inputs.xml having
  // been loaded, which this code cannot observe. Read this line with the per-press lines below it.
  KSTPLog.Info("input listeners registered: KSTP_CycleProtocol, KSTP_Overlay (presses are logged individually; no press lines means r6/input/kstp_inputs.xml was not loaded)");

  // A hold flag left raised from the previous session would pin the overlay open.
  KSTP_SetOverlayHold(this.GetGame(), false);

  // KSTPSettingsSystem and KSTPPolicySystem attach in either order; this is idempotent.
  KSTP_ReconcileSettings(this.GetGame());
}

@wrapMethod(PlayerPuppet)
protected cb func OnDetach() -> Bool {
  if IsDefined(this.kstpInputListener) {
    this.UnregisterInputListener(this.kstpInputListener, n"KSTP_CycleProtocol");
    this.UnregisterInputListener(this.kstpInputListener, n"KSTP_Overlay");
    this.kstpInputListener = null;
  };
  KSTP_SetOverlayHold(this.GetGame(), false);

  wrappedMethod();
}
