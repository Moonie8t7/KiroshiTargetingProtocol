// Kiroshi Smart Targeting Protocol: hotkeys.
//
// Two bindings, declared in src/r6/input/kstp_inputs.xml and surfaced for rebinding through
// Mod Settings (the `overridableUI` attribute in the XML resolves against the EInputKey field
// names on KSTPHotkeys in UI/Settings.reds):
//
//   KSTP_CycleProtocol: advance to the next targeting protocol
//   KSTP_Overlay:       raise the IFF overlay's hold flag (hold or toggle, per settings)
//
// The defaults are IK_K and IK_L. Every letter key IK_A..IK_Z is claimed by
// r6/config/inputUserMappings.xml on a stock install, so both defaults collide with a vanilla
// binding until they are rebound, which Mod Settings can do for either key.
//
// Dependencies. `ListenerAction` and `ListenerActionConsumer` (orphans.script:31981-32025) and
// `GameObject.RegisterInputListener` / `UnregisterInputListener` (gameObject.script:152-156)
// are base-game natives, not Codeware. The hotkey path below therefore compiles and runs with
// Codeware absent and is not gated on it: wrapping the listener in
// @if(ModuleExists("Codeware")) would disable hotkeys for players who do not have Codeware
// even though the code needs nothing from it. Every hotkey mod in the reference corpus uses
// this vanilla pattern, including CP77Mods\Immersive Timeskip\...\CustomTimeSkipListener.reds
// and CP77Mods\Limited HUD\r6\scripts\LHUD\core\listeners.reds:7-31. Codeware appears in that
// corpus only as Codeware.UI and Codeware.Localization, with no input module in use anywhere.
//
// Codeware is guarded below, where it is load-bearing: UI/Overlay.reds builds custom widgets,
// and KSTP_HasCodeware() is the compile-time probe for whether the rich overlay is available.
// It resolves to a constant, so it costs nothing at runtime.
//
// The one external requirement here is a loader for r6/input/*.xml (the Input Loader RED4ext
// plugin, or REDmod). Without it the bindings never fire and the listener is inert: no error,
// no crash, and the protocol is still fully selectable from the settings menu.

module KSTP.Input

import KSTP.Core.*

// ---------------------------------------------------------------------------
// Codeware capability probe
//
// @if(ModuleExists(...)) is resolved by the compiler, so exactly one of these two bodies is
// compiled. Guard pattern follows CP77Mods\Limited HUD\r6\scripts\LHUD\utils.reds:7-16.
// ---------------------------------------------------------------------------

@if(ModuleExists("Codeware"))
public func KSTP_HasCodeware() -> Bool {
  return true;
}

@if(!ModuleExists("Codeware"))
public func KSTP_HasCodeware() -> Bool {
  return false;
}

// ---------------------------------------------------------------------------
// Overlay hold channel
//
// The hotkey and the overlay live in different modules and different lifetimes, so they
// communicate through a bool on the UI_System blackboard rather than through a direct
// reference. The field, UI_SystemDef.KSTPOverlayHold, is declared by UI/Overlay.reds, which
// reads it in IsHoldActive(). This module only writes it.
// ---------------------------------------------------------------------------

public func KSTP_SetOverlayHold(gi: GameInstance, value: Bool) -> Void {
  let defs: ref<UI_SystemDef> = GetAllBlackboardDefs().UI_System;
  let bb: ref<IBlackboard> = GameInstance.GetBlackboardSystem(gi).Get(defs);
  if !IsDefined(bb) {
    return;
  };
  bb.SetBool(defs.KSTPOverlayHold, value, true);
}

public func KSTP_IsOverlayHeld(gi: GameInstance) -> Bool {
  let defs: ref<UI_SystemDef> = GetAllBlackboardDefs().UI_System;
  let bb: ref<IBlackboard> = GameInstance.GetBlackboardSystem(gi).Get(defs);
  if !IsDefined(bb) {
    return false;
  };
  return bb.GetBool(defs.KSTPOverlayHold);
}

// ---------------------------------------------------------------------------
// The listener
// ---------------------------------------------------------------------------

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
      // The master switch does not disable the hotkey. Cycling a protocol that is currently
      // flattened to vanilla is harmless, and refusing input with no feedback reads as a
      // broken keybind.
      if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
        this.CycleProtocol(gi);
      };
      return false;
    };

    if ListenerAction.IsAction(action, n"KSTP_Overlay") {
      if KSTP_Hotkeys(gi).kstpOverlayHoldMode {
        // Hold: raise on press, drop on release. The binding XML carries no <hold> element,
        // so the flag tracks the physical key with no arming delay.
        if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
          KSTP_SetOverlayHold(gi, true);
        } else {
          if Equals(actionType, gameinputActionType.BUTTON_RELEASED) {
            KSTP_SetOverlayHold(gi, false);
          };
        };
      } else {
        if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
          KSTP_SetOverlayHold(gi, !KSTP_IsOverlayHeld(gi));
        };
      };
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
    this.ShowProtocolMessage(gi, active.displayName, policy.IsArmed(), KSTP_Settings(gi).masterEnabled);
  }

  // On-screen confirmation. Cycling is otherwise invisible while the overlay is hidden, and
  // the message also states when the new protocol will not bite, either because the mod is
  // switched off or because nothing that takes a protocol is equipped. Blackboard write
  // pattern follows CP77Mods\Custom Map Markers\...\CustomMarkerSystem.reds:246-258.
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

// ---------------------------------------------------------------------------
// Registration
//
// Lifetime follows the player puppet, matching
// CP77Mods\Immersive Timeskip\...\PlayerPuppet-wrapped.reds:4-18. Registering per action name
// rather than globally keeps OnAction off the hot path for unrelated input.
// ---------------------------------------------------------------------------

@addField(PlayerPuppet)
private let kstpInputListener: ref<KSTPInputListener>;

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
  wrappedMethod();

  this.kstpInputListener = new KSTPInputListener();
  this.kstpInputListener.SetPlayer(this);
  this.RegisterInputListener(this.kstpInputListener, n"KSTP_CycleProtocol");
  this.RegisterInputListener(this.kstpInputListener, n"KSTP_Overlay");

  // A hold flag left raised from the previous session would pin the overlay open.
  KSTP_SetOverlayHold(this.GetGame(), false);

  // KSTPSettingsSystem and KSTPPolicySystem attach independently of each other, so whichever
  // lost the race is reconciled here, by which point both exist. Idempotent.
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
