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
| Mod Settings | Needed for configuration | Every option falls back to its compiled default: protocol AUTO, no per-class override, overlay on, faction filter off. The three experiment gates are read-only from here, so a result proved in the lab has nowhere to go. The mod still compiles and plays |
| Input Loader, or REDmod | Needed for hotkeys | `r6/input/kstp_inputs.xml` is never merged, so `KSTP_CycleProtocol` and `KSTP_Overlay` never fire. The listener stays registered and inert. Protocol selection still works from the settings menu |
| Codeware | Recommended | Two effects. The NPC spawn hook falls back from the `Entity/Attach` CallbackSystem path to `@wrapMethod(ScriptedPuppet) OnGameAttached`, and the two are equivalent for this purpose. The cyberware also loses its name: `UI/Localization.reds` compiles out, so the `LocKey#kstp_*` tokens on the item record resolve to nothing and the ripperdoc and inventory panels show it blank. Tier, capacity, price, description and every mechanic are unaffected. See [ADR 0008](adr/0008-display-names-via-codeware.md) |
| Cyber Engine Tweaks | Development only | The experiment lab in `experiments/cet/kstp_lab` cannot run, and the console shortcut for granting the cyberware is unavailable. Not needed to play |
| ArchiveXL | Not used | KSTP ships no `.archive` and no `.xl`. Nothing in the mod loads through it |

`tools/verify-env.ps1` prints the same list against a real install, marking each one INSTALLED,
PARTIAL or MISSING.

### Why Mod Settings is not a hard dependency

`ModSettings` is a native class registered by a RED4ext plugin, not a redscript module, so
`@if(ModuleExists("ModSettingsModule"))` is permanently false and guards nothing. Referencing
the symbol at all makes the plugin mandatory: without it the reference is unresolved and the
player's entire redscript load order fails to compile.

KSTP names no `ModSettings` symbol anywhere. The `@runtimeProperty` annotations are inert
metadata that cost nothing when the plugin is absent, and the settings refresh is driven off
the settings-menu-closed signal instead of the framework's change callback. A missing plugin
therefore degrades to compiled defaults rather than taking the load order down.

`r6/config/redsUserHints/KSTP.toml` carries friendly messages for missing TweakXL and Mod
Settings, as a safety net in case a future change reintroduces a reference.

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

The practical rule: `Strict` overrides another mod's added component classes wherever the
active protocol refuses them, and `Preferred` never touches the track stats at all. A player
running a cyberware or weapon overhaul that grants extra tracking classes should prefer
`Preferred`, which is the shipping default, or pick a protocol that permits those classes.

Neither side leaks. KSTP removes every modifier it applied before applying a new one, and
removes by handle rather than sweeping the stat, so another mod's modifier on the same stat is
never taken off.

### Mods that replace PauseMenuGameController.OnUninitialize

That method is the settings-menu-closed signal, and KSTP wraps it in `UI/Settings.reds` to run
`KSTPSettingsSystem.RefreshFromMenu()`. A mod that uses `@replaceMethod` on it discards every
other mod's wrap of the same method, KSTP included.

The visible result: settings changes appear to save but never bind. The menu shows the new
values, and the presets keep the old ones until something else forces a reconcile, which
happens on the next player attach (a load, or a world transition). Nothing is corrupted and
nothing needs repairing beyond reloading.

Mods known to wrap this method, and therefore to coexist with KSTP correctly, include Limited
HUD. Redscript chains multiple `@wrapMethod` bodies on one method rather than letting the last
one win.

### What KSTP itself hooks

KSTP uses only `@wrapMethod`, `@addMethod` and `@addField`. It contains no `@replaceMethod`,
so it never displaces another mod's behavior on a shared method, and it declares no `native
func` of its own, so it adds no hard dependency on a C++ plugin.

| Method or field | Where | Purpose |
|---|---|---|
| `PlayerPuppet.OnItemAddedToSlot` | Core/Policy.reds | Notice a weapon reaching the right hand |
| `PlayerPuppet.OnItemRemovedFromSlot` | Core/Policy.reds | Notice a weapon leaving it |
| `EquipmentSystem.OnInstallCyberwareRequest` | Core/Policy.reds | Notice the mod's cyberware being installed |
| `EquipmentSystem.OnUninstallCyberwareRequest` | Core/Policy.reds | Notice it being removed |
| `ScriptedPuppet.OnDetach` | Core/Classifier.reds | Drop the entity's cached classification axes |
| `ScriptedPuppet.OnGameAttached` | Enforcement/Faction.reds | Spawn hook, compiled only when Codeware is absent |
| `PauseMenuGameController.OnUninitialize` | UI/Settings.reds | Settings-menu-closed signal |
| `CrosshairGameController_Smart_Rifl.OnPreIntro` | UI/Overlay.reds | Attach the IFF overlay |
| `CrosshairGameController_Smart_Rifl.OnPreOutro` | UI/Overlay.reds | Detach it |
| `gameuiCrosshairBaseGameController.OnUninitialize` | UI/Overlay.reds | Detach it when the controller dies without an outro |
| `PlayerPuppet.OnGameAttached` | Input/Hotkeys.reds | Register the input listener |
| `PlayerPuppet.OnDetach` | Input/Hotkeys.reds | Unregister it |
| `@addField PlayerPuppet.kstpInputListener` | Input/Hotkeys.reds | Listener handle |
| `@addField CrosshairGameController_Smart_Rifl.kstpOverlay` | UI/Overlay.reds | Overlay handle |
| `@addField UI_SystemDef.KSTPOverlayHold` | UI/Overlay.reds | Hold-to-show blackboard channel |

A mod that replaces any of the wrapped methods above suppresses the corresponding KSTP feature
and nothing else. Each one degrades on its own.

### Hotkey conflicts

The default bindings are `K` for cycle protocol and `L` for the overlay. Both are declared in
`src/r6/input/kstp_inputs.xml` and are rebindable through the Mod Settings key-bindings group,
which resolves against the `EInputKey` field names on `KSTPHotkeys`. A conflict with another
mod's binding is resolved by rebinding either side; nothing in KSTP consumes the input event,
so a shared key fires both listeners.

### Overlay hosts

The IFF overlay attaches to `CrosshairGameController_Smart_Rifl` and its subclass
`CrosshairGameController_BlackwallForce`. A HUD replacement that removes or replaces that
controller removes the overlay with it. Enforcement is unaffected: it runs off the policy
system and the blackboard, not off the crosshair.

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

The mod ships no `.archive` and has no WolvenKit pack step, so a custom `LocKey#...` has
nothing to resolve against. TweakXL display strings therefore render as their LocKey text
in game, and every Mod Settings label is a literal English string rather than a key. Vanilla
LocKeys are still keys and still resolve, which is why the key-bindings group uses
`UI-Settings-KeyBindings`.
