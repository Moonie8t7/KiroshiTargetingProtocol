# Contributing to KSTP

The build and test loop, the tools, and the rules that are not negotiable.

Read these first:

| Document | Why |
|---|---|
| `docs/STYLE.md` | Binding prose and comment style for every shipped file |
| `docs/ARCHITECTURE.md` | The interface each module codes against, layer ownership, the two enforcement paths, and the five rules that hold across modules |
| `docs/adr/` | The decision behind anything that looks arbitrary. Cite a record by number rather than restating it |
| `docs/COMPATIBILITY.md` | Framework requirements and the hook surface |

---

## Prerequisites

- Cyberpunk 2077 build **2.31**, with RED4ext, redscript and TweakXL installed.
- Mod Settings, for the configuration surface.
- Codeware, for the NPC spawn hook and the coprocessor display names (ADR 0008).
- Cyber Engine Tweaks, for the experiment lab.
- The decompiled 2.31 game scripts at `<decompiled-scripts>`.
- WolvenKit, only to change the coprocessor icon. The built archive is committed, so a clone
  deploys and runs without it.

Every game API a change references must exist in that dump. If the symbol is not there, it
does not exist, and guessing a name produces either a compile error or a silent no-op.

PowerShell's default execution policy on Windows client is `Restricted`, which refuses to run
a `.ps1` at all. Invoke every script in `tools/` with an explicit bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1
```

That is per-process and changes no machine-wide setting. `verify-env.ps1` prints which
frameworks are installed, which content directories exist, where each log lives, and whether
KSTP is currently deployed.

---

## Deploying

`tools/deploy.ps1` copies the three deployable trees into a game install:

```text
src\r6                     ->  <game>\r6
src\archive                ->  <game>\archive          (optional; excludes src\archive\source)
experiments\cet\kstp_lab   ->  <game>\bin\x64\plugins\cyber_engine_tweaks\mods\kstp_lab
```

**Always dry-run first.** The dry run prints exactly what a real run would write, in the same
format:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -WhatIf
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1
```

| Flag | Effect |
|---|---|
| `-WhatIf` | Preview. Nothing is written |
| `-Clean` | Replay the per-install manifest and remove exactly the files the deploy wrote, then prune the empty KSTP-owned directories |
| `-Force` | Copy every file even when the destination matches by size and timestamp. Use after an interrupted deploy |
| `-Quiet` | Summary line only |
| `-GamePath` | Target a non-default install. Falls back to `$env:KSTP_GAME_PATH`, then to the script default |

`-Clean` combines with `-WhatIf` and should, the first time on any install:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -Clean -WhatIf
```

The manifest lives in `tools/.deploy-manifests`, keyed by install path, never inside the game
directory. The script refuses to write to a directory without `bin\x64\Cyberpunk2077.exe`, and
directory removal goes through `[System.IO.Directory]::Delete(path, $false)`, which throws
rather than recursing.

`tools/watch.ps1` re-runs the deploy on every change under `src/` and `experiments/cet/`, with
a debounce window. Redscript compiles at game launch, so a deploy while the game is running
takes effect on the next launch.

---

## Compile-checking without launching the game

A full launch cycle is slow. `redscript-cli` compiles the sources against the game's script
bundle and reports the same errors the in-game compiler would:

```powershell
redscript-cli compile `
  -s .\src\r6\scripts `
  -b 'C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077\r6\cache\final.redscripts' `
  -o "$env:TEMP\kstp-check.redscripts"
```

Three things to get right:

1. **Point `-o` at a scratch file.** Writing over the game's own
   `r6\cache\final.redscripts` replaces the compiled bundle with a KSTP-only build and breaks
   the install until the file is restored.
2. **`-b` must be the untouched bundle**, not `r6\cache\modded\final.redscripts`.
3. **Compiling `src\r6\scripts` alone checks KSTP in isolation.** To reproduce the player's
   real load order, point `-s` at the deployed `<game>\r6\scripts` instead, so every other
   installed mod's sources are in the same compilation.

Every `@if(ModuleExists(...))` branch resolves at compile time against whatever is in `-s`.
Framework guards ship at four sites: `Codeware` over the spawn hook in
`Enforcement/Faction.reds` and over the probe in `Input/Hotkeys.reds`, `Codeware.Localization`
over the display strings in `UI/Localization.reds`, and `ModSettingsModule` over the menu
write-back in `UI/Settings.reds` (ADR 0008, ADR 0010). Those frameworks keep their scripts
under `red4ext\plugins\...` rather than `r6\scripts`, and RED4ext adds those directories to the
in-game compiler's source set, so neither `-s` above reaches them: an isolated check compiles
the counterpart body of every guard, and the guarded half is exercised only in game. Check both
arrangements before changing anything inside those guards.

---

## Logs

| Log | Path | What it tells you |
|---|---|---|
| redscript compile | `r6\logs\redscript_rCURRENT.log` | Read this first. Every syntax error, type error and unresolved symbol |
| cybercmd | `r6\logs\cybercmd_rCURRENT.log` | Whether `scc.exe` was launched at all. An empty redscript log usually means this failed |
| TweakXL | `red4ext\logs\TweakXL-*.log` | Whether `src/r6/tweaks/KSTP` parsed and whether the cyberware record was created |
| RED4ext | `red4ext\logs\` | Plugin load failures, one log per plugin |
| game log | `bin\x64\plugins\cyber_engine_tweaks\gamelog.log` | Every `KSTPLog` line. `FTLog` output is captured here when CET is installed |
| CET scripting | `bin\x64\plugins\cyber_engine_tweaks\scripting.log` | Lua errors from the experiment lab |

`KSTPLog.Info` is for startup, teardown and protocol switches. Diagnostics are
`KSTPLog.Debug`, behind `KSTP_DebugLoggingEnabled()` in `Core/Log.reds`, which reads the Mod
Settings switch on every call and allocates a config object to do it, so tracing turns on
without a recompile and no call site is free. A shipped build must not log per frame or per
entity at Info level. Test `KSTPLog.DebugEnabled()` before building an interpolated string
inside a hot loop, and hoist that test out of a loop that runs per target per frame, as
`KSTPFactionSystem.ReevaluateTracked()` does.

---

## The CET developer lab

`experiments/cet/kstp_lab` is the measurement rig: a CET Lua mod with panels for the five
experiments, live readouts of the smart-gun blackboard, hotkeys that work with the CET overlay
closed, and a report writer.

Its runbook is `experiments/cet/kstp_lab/README.md`, accurate to `init.lua` panel by panel.
`deploy.ps1` installs it alongside the mod, or copy the `kstp_lab` folder by hand to
`<game>\bin\x64\plugins\cyber_engine_tweaks\mods\kstp_lab`.

Use it for anything that claims a native behaviour. Everything it mutates is tracked and
unwound, on `onShutdown` and through the panic hotkey, and the outstanding-mutations line says
whether anything is still applied. Reload the save rather than trusting a crash to clean up.

The `redscript_probe/` subfolder is not loaded by CET. It is only needed if the E-FILTER
control step passes.

---

## Rebuilding the coprocessor icon

Only needed to change the artwork. `src/archive/pc/mod/kstp.archive` is committed, so nothing
here is required to build, deploy or run the mod (ADR 0015).

The WolvenKit project is `src/archive/source/KSTP`. Its raw input is a single square PNG at
`source/raw/base/kstp/icons/kstp_coprocessor.png`, currently 160 x 160. The full-resolution
master it was reduced from is kept outside the project at
`src/archive/source/artwork/kstp_coprocessor_master.png`, so a different size can be exported
without redrawing anything. Nothing builds from the master directly.

1. Export the size you want from the master, then replace the project's raw PNG with it, keeping
   the name and a square size.
2. Import it to `.xbm`, then generate the atlas from **the project's own raw folder**, never from
   a directory holding several PNGs. The generator emits one atlas part per file it finds, and
   the extra parts are silent: the archive still builds and the icon still fails to resolve.
3. Confirm the built atlas has exactly one part, named `kstp_coprocessor`.
4. Pack, then copy the packed archive to `src/archive/pc/mod/kstp.archive`.
5. Deploy and check the item card in the inventory.

While repacking, drop `kstp_coprocessor_1080.xbm` from `custom_refs.txt` and from the project.
Nothing references it: the atlas has a single part and the item record names only that part, so
the texture is packed into every shipped archive and never read. It was left in place rather than
removed by hand, because editing the reference list without repacking would leave the committed
archive unreproducible from the committed sources.

The part name is the failure that hides. `atlasPartName` in `src/r6/tweaks/KSTP/cyberware.yaml`
must match the name inside the built atlas exactly. A mismatch raises no TweakDB error and logs
nothing; the icon simply falls through to the native resolver.

WolvenKit's own `packed/`, `.projectFiles/` and export `.zip` are build outputs and are ignored
by git.

---

## Hard rules

These are not preferences. Each one exists because breaking it has a specific, known failure
mode.

**No `@replaceMethod`, anywhere** (ADR 0002). Use `@wrapMethod` or `@addMethod`. Redscript
chains multiple wraps of one method; a full-body replace discards every other mod's wrap of it
and silently reverts vanilla behaviour on the next patch. If a replace looks unavoidable, stop
and raise it instead of writing it.

**No `native func` declarations** (ADR 0001). That creates a hard dependency on a C++ plugin
this project does not ship, and an unresolved native symbol takes down the player's entire
redscript load order, not just this mod.

**Check for an existing method of the same name before adding one to a class.** A duplicate
method on a `ScriptableSystem` compiles clean and then kills the game at RTTI registration,
before the main menu, with no log line. The classes in `Enforcement/Faction.reds` and
`UI/Settings.reds` are large enough that this is a real hazard.

**A clean compile does not prove the mod loads.** The compile log reporting "Compilation
complete, 0 errors" is compatible with a game that crashes before the main menu: a duplicate
method name, as above, is caught at RTTI registration rather than at compile time and reports
nothing. Naming a framework class such as `ModSettings` is not that failure mode. The plugin
puts its own `module.reds` and `packed.reds` into the compiler's source set, so
`@if(ModuleExists("ModSettingsModule"))` is true with the plugin installed and false without
it, and the guarded body compiles out rather than resolving against nothing (ADR 0010). Launch
to the main menu, load a save, and read the log before calling a change good.

**Restore what you mutate, and only what you mutate.** Every stat modifier applied to a world
entity is tracked with its exact `gameStatModifierData` handle and removed with
`StatsSystem.RemoveModifier`. `RemoveAllModifiers` strips every non-saved modifier on the stat
regardless of origin and would delete another mod's or a quest effector's work.

**Degrade, never fail.** Every gated feature no-ops cleanly with its gate off, and the mod must
be fully playable with every gate false. Guard optional dependencies with
`@if(ModuleExists("..."))`.

**Prefix everything.** Classes `KSTPFoo`, free functions `KSTP_Foo`. This mod shares one global
namespace with every other redscript mod on the install.

---

## Before opening a pull request

1. `verify-env.ps1` passes on the target install.
2. `redscript-cli compile` returns clean against the untouched bundle.
3. `deploy.ps1 -WhatIf` shows the file set you expect, then a real deploy.
4. The game reaches the main menu, a save loads, and `redscript_rCURRENT.log` has zero errors.
5. The cyberware grants and equips, and the IFF labels draw over tracked targets, moving from
   `OFFLINE` to `PERMIT`, `REFUSE` or `REFUSE*` when a smart weapon is drawn.
6. Every new game API reference cites `file.script:line` from the 2.31 dump.
7. The diff contains no `@replaceMethod`, no `native func`, and no new duplicate method name.
8. Prose and comments follow `docs/STYLE.md`.
