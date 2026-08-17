# 0010. Mod Settings is a soft dependency

## Status

Accepted.

## Context

The Mod Settings box labelled "Active protocol" reported AUTO while the protocol actually in
force was whichever one the hotkey had last cycled to. A player who pressed the cycle key, saw
the on-screen confirmation, then opened the settings page was told the protocol was still AUTO.

The box was write-only by design, and `UI/Settings.reds` said so at the point of the decision:

> Protocol selection is owned by `KSTPPolicySystem` and persisted into the save, so the menu is a
> write-only control: it pushes on an actual edit and never mirrors back.

That much was a real constraint. `m_activeProtocolId` is `persistent` and rides in the save;
Mod Settings persists its own copy to `user.ini`. Two stores, and the save was made authoritative
so an unrelated settings edit could not stamp AUTO over a hotkey selection.

The reason given for never mirroring back was not real. The file header asserted:

> `ModSettings` is a native class registered by a RED4ext plugin, not a redscript module, so
> `@if(ModuleExists("ModSettingsModule"))` is permanently false and would compile the whole
> integration out for every player.

Every clause of that is false on this install, and checking took one look at the plugin directory:

| Claim | Actual |
|---|---|
| Not a redscript module | `red4ext\plugins\mod_settings\module.reds` declares `module ModSettingsModule` |
| Symbol unavailable to the compiler | `packed.reds` declares `public native class ModSettings`, and RED4ext adds that directory to the compiler's source set |
| Guard permanently false | Both files appear in `r6\logs\redscript_rCURRENT.log` beside `r6\scripts` |
| Naming it makes the plugin required | Eight installed mods name it behind that guard, among them Audioware, `auto_drive_enhanced` and BrowserExtension |

The guard behaves exactly as the Codeware guards in `Enforcement/Faction.reds` and
`Input/Hotkeys.reds` already do: true with the plugin present, false without it, guarded body
compiled out rather than left unresolved.

The API needed was already there: `ConfigVar.GetName()` to find the field,
`ModConfigVarEnum.SetIndex()` to move it, `ModSettings.AcceptChanges()` to persist.

## Decision

Mod Settings is a soft dependency, on the same terms as Codeware.

- Anything that must name `ModSettings` sits behind `@if(ModuleExists("ModSettingsModule"))`
  with an empty counterpart, so the mod still compiles and plays with the plugin absent.
- `KSTP_WriteProtocolToMenu()` pushes the live protocol into the box after the hotkey moves it,
  so the control shows the protocol actually in force. Lookup walks the mod's registered
  categories and matches on `ConfigVar.GetName()`, following `auto_drive_enhanced\settings.reds`
  in the installed corpus, rather than assuming the position of the only enum in `General`.
- The menu-to-mod direction still runs off the settings-menu-closed signal
  (`PauseMenuGameController.OnUninitialize`). That path needs nothing from the framework, so it
  stays primary and the write-back is additive.
- The save remains authoritative for the protocol. This record changes what the menu is allowed
  to display, not which store owns the value.

## Consequences

The box now agrees with the mod. That was the whole point, and it is worth being blunt about the
size of the thing that prevented it: a comment asserting an API was unavailable, believed for as
long as it went unchecked, in a file whose own header describes the corpus it was supposedly
derived from.

Without the plugin, `KSTP_WriteProtocolToMenu` compiles to an empty function and there is no menu
to correct, which is the same shape as Codeware's absence under [0008](0008-display-names-via-codeware.md).

`AcceptChanges()` persists the whole page to `user.ini`, so the write-back tests
`GetIndexFor()` against the current index and does nothing when the value has not moved. The
cycle key can be held down.

The generalisable failure is not the wrong API claim. It is that the claim was load-bearing,
specific, checkable in one command, and carried a full paragraph of justification, which is what
made it read as settled. Prose confidence in a comment is not evidence, and the more precise a
comment's reasoning sounds, the more it is worth running the one command that tests it.
