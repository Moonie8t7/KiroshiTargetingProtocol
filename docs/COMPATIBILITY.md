# KSTP - compatibility

Frameworks the mod needs, what breaks when one is missing, which other mods contend with it,
and what it does to a save.

Game build: **2.31**. A different build may move native offsets under the frameworks; nothing
in KSTP compensates for that.

---

## Framework requirements

| Framework | Status | What breaks without it |
|---|---|---|
| RED4ext | Required | Hosts TweakXL, Mod Settings and Codeware. None of them load, so the cyberware record never exists and the mod can never arm |
| redscript (with cybercmd) | Required | Nothing under `r6/scripts` is compiled. KSTP is redscript, so the mod is simply absent |
| TweakXL | Required | `src/r6/tweaks/KSTP` never loads. the `Items.KSTPKiroshiIFFCoprocessor*` records do not exist, `KSTP_HasCyberwareInstalled()` is permanently false, `IsArmed()` is permanently false, and the scripts run inert |
| Mod Settings | Needed for configuration | Every option falls back to its compiled default: protocol AUTO, every target class on except VEHICLE, lock policy inherited from the protocol, overlay visibility ALWAYS, faction filter on with NCPD, Trauma Team, Aldecaldos and Afterlife mercs unticked. The three experiment gates are read-only from here, so a result proved in the lab has nowhere to go, and `KSTP_WriteProtocolToMenu()` compiles to an empty function. The mod still compiles and plays |
| Input Loader, or REDmod | Needed for hotkeys | `r6/input/kstp_inputs.xml` is never merged, so `KSTP_CycleProtocol` and `KSTP_Overlay` never fire. The listener stays registered and inert. Protocol selection still works from the settings menu |
| Codeware | Recommended | Two effects. The NPC spawn hook falls back from the `Entity/Attach` CallbackSystem path to `@wrapMethod(ScriptedPuppet) OnGameAttached`, and the two are equivalent for this purpose. The cyberware also loses its name: `UI/Localization.reds` compiles out, so the `LocKey#kstp_*` tokens on the item record resolve to nothing and the ripperdoc and inventory panels show the name and flavour text blank. Tier, capacity, price, the gameplay logic package's own name and description, and every mechanic are unaffected. See [ADR 0008](adr/0008-display-names-via-codeware.md) |
| Cyber Engine Tweaks | Development only | The experiment lab in `experiments/cet/kstp_lab` cannot run, and the console shortcut for granting the cyberware is unavailable. Not needed to play |
| ArchiveXL | Needed for the icon | `archive/pc/mod/kstp.archive` does not load, so `UIIcon.KSTPCoprocessor` resolves to nothing and the coprocessor falls back to a stock icon. The item, its tiers and every mechanic are unaffected. See [ADR 0015](adr/0015-the-mod-ships-an-archive.md) |

`tools/verify-env.ps1` prints the same list against a real install, marking each one INSTALLED,
PARTIAL or MISSING.

### Why Mod Settings is not a hard dependency

The plugin ships `red4ext\plugins\mod_settings\module.reds`, which declares
`module ModSettingsModule`, and `packed.reds`, which declares `public native class ModSettings`.
RED4ext adds that directory to the compiler's source set, so
`@if(ModuleExists("ModSettingsModule"))` is true when the plugin is installed and false when it
is not, behaving exactly as the Codeware guards do. See
[ADR 0010](adr/0010-mod-settings-is-a-soft-dependency.md).

`KSTP_WriteProtocolToMenu()` in `UI/Settings.reds` is the only code that names `ModSettings`, and
it sits behind that guard with an empty counterpart. It pushes the live protocol id into the
"Active protocol" box after the hotkey has moved it, so the box follows the hotkey and the hotkey
follows the box. Without the plugin it compiles to an empty function and there is no menu to
correct.

Everything else is annotation. The `@runtimeProperty` entries are inert metadata that cost
nothing when the plugin is absent, and the menu-to-mod refresh is driven off the
settings-menu-closed signal instead of the framework's change callback, so that direction needs
nothing from the framework either. A missing plugin degrades to compiled defaults rather than
taking the load order down.

`r6/config/redsUserHints/KSTP.toml` carries friendly messages for missing TweakXL and Mod
Settings, in case a `ModSettings.` reference ever escapes its guard.

---

## Mod interactions

### Mods that write SmartGunTrack* stats on the same weapon

Anything that writes `SmartGunTrackHeadComponents`, `SmartGunTrackChestComponents`,
`SmartGunTrackLegComponents`, `SmartGunTrackWeakSpotComponents`,
`SmartGunTrackMechanicalComponents`, `SmartGunTrackBreachComponents` or
`SmartGunTrackVehicleComponents` on the held weapon's stats object contends with the KSTP
body-part layer. Examples seen in the wild: **ChipwareExpansion**, and the **misoru** weapon
packs. Vanilla does it too, through `Items.KiroshiOpticsFragment1`.

What actually happens depends on the active lock policy:

| KSTP lock policy | Class permitted by the protocol | Class refused by the protocol |
|---|---|---|
| Strict | The other mod's contribution stands, unchanged | KSTP writes a `Multiplier` 0 modifier, which zeroes the stat whatever the other mod added |
| Preferred | The other mod's contribution stands, unchanged | The track stat is untouched. KSTP inflates the time-to-lock multiplier instead, so the class stays enabled but loses the lock race |

Vehicle is the one exception, under either policy: whenever the Vehicle class is refused,
`SmartGunTrackVehicleComponents` is zeroed the same way `Strict` zeroes any other class, because
lock-time inflation was measured to have no effect on a car. See
[ADR 0013](adr/0013-each-axis-enforces-its-own-question.md).

The practical rule: `Strict` overrides another mod's added component classes wherever the
active protocol refuses them, and `Preferred` touches no track stat except
`SmartGunTrackVehicleComponents`. A player running a cyberware or weapon overhaul that grants
extra tracking classes should prefer `Preferred`, which the default AUTO protocol ships and the
INHERIT lock-policy setting therefore selects out of the box, or pick a protocol that permits
those classes.

Neither side leaks. KSTP removes every modifier it applied before applying a new one, and
removes by handle rather than sweeping the stat, so another mod's modifier on the same stat is
never taken off.

### Mods that replace PauseMenuGameController.OnUninitialize

That method is the settings-menu-closed signal, and KSTP wraps it in `UI/Settings.reds` to run
`KSTPSettingsSystem.RefreshFromMenu()`. A mod that uses `@replaceMethod` on it discards every
other mod's wrap of the same method, KSTP included.

The visible result: settings changes appear to save but never bind. The menu shows the new
values, and the presets keep the old ones until `KSTPSettingsSystem` re-reads the menu, which
it does on its own attach, so a save load recovers them. Nothing is corrupted and nothing needs
repairing beyond reloading.

Mods known to wrap this method, and therefore to coexist with KSTP correctly, include Limited
HUD. Redscript chains multiple `@wrapMethod` bodies on one method rather than letting the last
one win.

### What KSTP itself hooks

KSTP uses only `@wrapMethod` and `@addField`. It contains no `@replaceMethod`, so it never
displaces another mod's behaviour on a shared method, and it declares no `native func` of its
own, so it adds no hard dependency on a C++ plugin.

| Method or field | Where | Purpose |
|---|---|---|
| `PlayerPuppet.OnItemAddedToSlot` | Core/Policy.reds | Notice a weapon reaching the right hand |
| `PlayerPuppet.OnItemRemovedFromSlot` | Core/Policy.reds | Notice a weapon leaving it |
| `EquipmentSystemPlayerData.OnEquipRequest` | Core/Policy.reds | Notice the mod's cyberware being installed. Fires for every equipment change, not only cyberware, so the handler re-reads the tier and leaves the no-change guard in `Reapply()` to discard the rest |
| `EquipmentSystemPlayerData.OnUnequipRequest` | Core/Policy.reds | Notice it being removed, on the same terms |
| `ScriptedPuppet.OnDetach` | Core/Classifier.reds | Drop the entity's cached classification axes |
| `ScriptedPuppet.OnGameAttached` | Enforcement/Faction.reds | Spawn hook, compiled only when Codeware is absent |
| `PauseMenuGameController.OnUninitialize` | UI/Settings.reds | Settings-menu-closed signal |
| `CrosshairGameController_Smart_Rifl.OnPreIntro` | UI/Overlay.reds | Attach the IFF overlay when a smart weapon is raised |
| `CrosshairGameController_Smart_Rifl.OnSmartGunParams` | UI/Overlay.reds | Per-frame smart-gun payload: draws the overlay and drives the faction axis. Also attaches the overlay if the intro never ran, which is the case after a save load restores the player holding the weapon |
| `CrosshairGameController_Smart_Rifl.OnPreOutro` | UI/Overlay.reds | Detach it |
| `gameuiCrosshairBaseGameController.OnUninitialize` | UI/Overlay.reds | Detach it when the controller dies without an outro |
| `PlayerPuppet.OnGameAttached` | Input/Hotkeys.reds | Register the input listener |
| `PlayerPuppet.OnDetach` | Input/Hotkeys.reds | Unregister it |
| `@addField PlayerPuppet.kstpInputListener` | Input/Hotkeys.reds | Listener handle |
| `@addField CrosshairGameController_Smart_Rifl.kstpOverlay` | UI/Overlay.reds | Overlay handle |
| `@addField UI_SystemDef.KSTPOverlayHold` | UI/Overlay.reds | Hold-to-show blackboard channel |

A mod that replaces any of the wrapped methods above suppresses the corresponding KSTP feature
and nothing else, with one exception. `OnSmartGunParams` is the single delivery point for the
per-frame smart-gun payload, because a `RegisterDelayedListener*` from outside an ink game
controller never fires on this build, so replacing it takes out both the overlay and the faction
axis's continuous driver at once. See
[ADR 0012](adr/0012-blackboard-delivery-via-the-host-controller.md). Every other wrap degrades on
its own.

### Hotkey conflicts

The default bindings are `[` (`IK_LeftBracket`) for cycle protocol and `]` (`IK_RightBracket`)
for the overlay. Letter keys are avoided because vanilla `r6/config/inputUserMappings.xml`
claims every `IK_A`..`IK_Z` on a stock install. Both are declared in
`src/r6/input/kstp_inputs.xml` and are rebindable through the Mod Settings key-bindings group,
which resolves against the `EInputKey` field names on `KSTPHotkeys`. A conflict with another
mod's binding is resolved by rebinding either side; nothing in KSTP consumes the input event,
so a shared key fires both listeners.

### Overlay hosts

The IFF overlay attaches to `CrosshairGameController_Smart_Rifl` and its subclass
`CrosshairGameController_BlackwallForce`. A HUD replacement that removes or replaces that
controller removes the overlay and the faction axis's per-frame driver with it, since both take
delivery from that controller's own `OnSmartGunParams` ([ADR 0012](adr/0012-blackboard-delivery-via-the-host-controller.md)).
Body-part enforcement is unaffected: it runs off the policy system and the weapon-slot callback,
not off the crosshair. The faction axis degrades to the spawn hook and the reapply path, so it
still acts on protocol changes, loadout changes and settings-menu closes, but stops following
targets as they are acquired.

---

## Save safety

**Nothing KSTP applies to the world survives a reload.** Every modifier goes through
`StatsSystem.AddModifier` (`orphans.script:16943`), which is the non-saved form, never
`AddSavedModifier` (`:16947`). A load drops all of them, whether or not the mod is still
installed.

| State | Persisted | Notes |
|---|---|---|
| Active protocol id | Yes | One `Int32` on `KSTPPolicySystem`. Clamped to a valid preset on restore, falling back to AUTO |
| Weapon stat modifiers | No | Rebuilt on draw by the slot callback |
| NPC suppression modifiers | No | The ledger is reset on `OnRestored`, so stale IDs are never carried forward |
| Settings and gates | Outside the save | Mod Settings keeps its own file. An experiment result is a fact about the install, not about the playthrough, and survives starting a new game |
| Classification cache | No | Session-scoped, rebuilt on demand |

The cyberware item is a TweakXL record. Uninstalling the mod removes the record, so unequip
any `Items.KSTPKiroshiIFFCoprocessor*` tier and drop it before removing KSTP, the same as for any other
TweakXL item mod.

`tools/deploy.ps1 -Clean` removes exactly the files the deploy wrote, replayed from a
per-install manifest kept inside the project.

---

## Display strings

The custom `LocKey#kstp_*` tokens the item record cites are registered from script, through
Codeware's localization system in `UI/Localization.reds`
([ADR 0008](adr/0008-display-names-via-codeware.md)). The archive the mod now ships carries the
icon only ([ADR 0015](adr/0015-the-mod-ships-an-archive.md)); moving the strings into it as a
cooked `JsonResource` would trade the Codeware dependency for an ArchiveXL one and is not
proposed.
With Codeware absent that file compiles out and the tokens resolve to nothing:
`GetLocalizedItemNameByCName` (orphans.script:20082) hashes its argument and returns an empty
string on a miss, so the item renders nameless rather than showing the key.

Gameplay logic package UIData strings are plain scalars, not keys. They resolve through
`GetLocalizedText` (orphans.script:19622), which returns its input, so they render with no
dependency at all. Every Mod Settings label is likewise a literal English string rather than a
key. Vanilla LocKeys are still keys and still resolve, which is why the key-bindings group uses
`UI-Settings-KeyBindings`.
