# KSTP Lab - the experiment runbook

This is **the** runbook for the Kiroshi Smart Targeting Protocol. It is written for you sitting
at the game with a mouse in hand, and it is accurate to `init.lua` panel for panel: every button
name below is the literal label on the button.

Run this rig **before** any of the mod's gated features are trusted. Three of the gates in
`Core/Gate.reds` - `FactionAxisEnabled`, `LiveStatReread`, `IgnoreListWorks` - are set from what
these experiments prove on *your* build. Every gate is off by default, and the mod is fully
playable with all of them off. Turning one on because you would like it to be true, rather than
because you watched it happen, gives you a mod that silently does nothing where it claims to act.

Game version: **2.31**. Requires Cyber Engine Tweaks (>= 1.18, for `FromVariant`).

There are exactly five experiments: **E-STAT**, **E-TRACK**, **E-IGNORE**, **E-FILTER**,
**E-AIMASSIST**. If you have seen a doc naming E-ADS or E-BB, it was wrong and has been deleted.

---

## The five at a glance

| ID | Question | Panel | Sets |
|----|----------|-------|------|
| **E-STAT** | Can a stat modifier on *one target NPC* stop that NPC being smart-locked? | 2 | `KSTPGate.FactionAxisEnabled` |
| **E-TRACK** | Does the handler re-read the weapon's track stats live, or only on draw? | 3 | `KSTPGate.LiveStatReread` |
| **E-IGNORE** | Does `AddIgnoredLookAtEntity` reach the smart-lock pipeline? | 4 | `KSTPGate.IgnoreListWorks` |
| **E-FILTER** | Can a script-side `TargetFilter_Script.Filter()` body run at all? | 5 | nothing yet - records a lead |
| **E-AIMASSIST** | Does the aim-assist preset touch smart lock? (expected: no) | 6 | nothing - closes a dead lead |

E-STAT is the decisive one. E-IGNORE is the one that would be *better* if it passes.

---

## Before you start

### 1. Check the environment

Windows 11 ships with PowerShell's execution policy set to `Restricted`, which refuses to run a
`.ps1` file at all. Invoke the project's scripts with an explicit bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1
```

Or, if you would rather relax the policy once for the current console only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\tools\verify-env.ps1
```

`Set-ExecutionPolicy -Scope Process` lasts until you close that window and changes nothing
permanently. Never use `-Scope LocalMachine` for this.

You need **Cyber Engine Tweaks** in the INSTALLED column. Without it there is no lab and no
experiments - which is a fine place to stop; the mod just runs with every gate off forever.

### 2. Mod Settings is not optional - it is the only way to record a result

`Core/Gate.reds` reads the three gates **only** from Mod Settings
(jackhumbert's `red4ext\plugins\mod_settings`). There is no console command, no config file and
no CET fallback. Without that plugin, `KSTPGateConfig` yields its compiled defaults and all three
gates read `false` no matter what you prove in here.

So: if Mod Settings is MISSING in `verify-env.ps1`, install it before you run a single
experiment. Otherwise you will get a clean PASS and have nowhere to put it.

### 3. Deploy

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -WhatIf # dry run first
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1
```

That copies `src\r6` into the game and this folder into
`Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\kstp_lab\`, so you end up with
`mods/kstp_lab/init.lua`.

To install the lab by hand instead, just copy the whole `kstp_lab` folder to that path.

The `redscript_probe/` subfolder is *not* loaded by CET. It is only needed if E-FILTER's control
step passes - see experiment 4.

### 4. Open the lab

Launch the game and press the CET overlay key. **The default is the backquote key**
<kbd>`</kbd> - the one left of `1`, above Tab. Not <kbd>Ctrl</kbd>+<kbd>~</kbd>. The
**KSTP Lab** window is in the overlay's window list.

### 5. Bind the hotkeys first - the procedures do not work without them

**CET > Bindings > KSTP Lab.** This is not optional polish. You cannot aim a weapon while the CET
overlay has input focus, and E-STAT, E-TRACK and E-IGNORE all require you to alternate between
aiming down sights and acting on a target. With the overlay open you cannot aim; with it closed
you cannot click a button. The hotkeys are the only way out of that.

Bind at least these five:

| Hotkey label in CET | Why it matters |
| --- | --- |
| `KSTP: pin look-at target` | Aim at an NPC with the overlay **closed**, press this, then open the overlay and act on the pinned target. |
| `KSTP: E-STAT apply to pinned target` | Applies the E-STAT modifier mid-fight without pausing. |
| `KSTP: E-STAT clear all` | Undo, mid-fight. |
| `KSTP: E-TRACK zero head+chest` | The whole E-TRACK observation happens in about two seconds of live combat. |
| `KSTP: PANIC restore everything` | Removes every stat modifier, ignore entry, filter ticket and aim preset swap. |

Two more exist and are useful but not load-bearing: `KSTP: toggle pinned readout` and
`KSTP: E-TRACK restore`.

The **pinned HUD readout** (small translucent window, top-left, checkbox at the top of the main
window) stays visible with the overlay closed and is click-through. That is where you watch the
live lock list while actually aiming.

### 6. Get a proper test spot

- A **smart weapon** equipped - Yinglong, Ashura, Shingen, Divided We Stand, Skippy, a
 Smart-modded pistol. The status line at the top of the lab prints `[SMART]` or
 `[<evolution> - not smart]`, so you do not have to guess.
- The **Smart Link** cyberware in a hand slot. Without it smart weapons do not lock at all and
 every experiment below reads as a false FAIL.
- **Two or more hostiles** of the same kind, alive, standing still, at similar distance. Gang
 encounters and NCPD "assault in progress" spots work well.
- **Distance.** Stand far enough back that a lock takes a visible moment to build. At point-blank
 range everything locks instantly and you will not be able to tell anything apart. This matters
 more than it sounds - see the E-STAT false-negative trap.
- A **throwaway manual save**. The lab pokes live NPCs. Everything it touches it also puts back,
 and none of it is written into your save, but do not do this mid-quest.

### 7. Smoke test: prove the mod itself is loaded

Before measuring anything, confirm the redscript side is alive. From the **CET console** tab:

```lua
Game.AddToInventory("Items.KSTPKiroshiIFFCoprocessorLegendaryPlusPlus", 1)
```

That record name is authored at `src/r6/tweaks/KSTP/cyberware.yaml` (the `Items.` key), and
`Core/Policy.reds` matches on the same string via `KSTP_CyberwareID()`. If the console errors or
nothing arrives, TweakXL did not load the YAML - stop and fix that first.

Then equip it (Inventory > Cyberware > Frontal Cortex; it is also stocked at Viktor Vektor) and
draw a smart weapon. `KSTPPolicySystem.IsArmed()` is true only when **both** halves hold - cyberware installed *and* a smart weapon in hand - and you can see it flip on the IFF overlay:
the chip on each tracked target reads `OFFLINE` while unarmed and `PERMIT` / `REFUSE` once armed.
Holster the weapon and it goes back to `OFFLINE`.

---

## Run order

Ordered by information value, not convenience. Do not skip step 0.

### 0. LIVE READOUT - build confidence in the instrument

Section **1. LIVE READOUT (smart-gun blackboard)**. Equip a smart weapon and aim at people. You
should see numbered rows with `state`, `[LOCKED]`, distance, accuracy and bone, plus a resolved
`AFF / ATT / RAR / TYPE` line per target.

If the panel prints a coloured error line instead - `SmartGunParams is empty - equip a smart
weapon and aim (ADS)`, `UI_ActiveWeaponData blackboard not resolved`, or
`FromVariant(SmartGunParams) failed` - the rig cannot see the game and **every reading below is
untrustworthy**. Stop and fix it. If it prints `blackboard reachable, target list empty`, the
blackboard is fine and there is simply nothing being tracked right now.

The panel does **not** tell you which of the empty-list causes applies; it cannot distinguish
them. Work down this list yourself:

- no smart weapon equipped (the status line at the top says so), or
- not aiming - the smart-gun handler is only latched during ADS on most smart guns, or
- no Smart Link cyberware, so the game's own `hasRequiredCyberware` flag is false and the handler
 never runs. The lab does not read that flag; check your hand slot.

`AFF=-` is expected for drones, turrets, vehicles and devices: they have no `Character_Record`.
`ATT=...(no agent)` means the entity has no attitude agent, so its attitude value is meaningless
rather than merely neutral - the same trap `Core/Classifier.reds` has to handle.

**TARGET SELECTION** sits just below. Use `pin current look-at`, or the `pin look-at target`
hotkey with the overlay closed, or `pin from lock list[1]` to grab whatever the gun is tracking
first. Everything the experiments act on is the pin if set, otherwise whatever is under the
crosshair right now.

---

### 1. E-STAT - the decisive one

Section **2. E-STAT -- per-NPC time-to-lock [DECISIVE]**.

**Question:** can a `SmartGunTimeToLock*ComponentMultiplier` modifier applied to a *target NPC's*
stats object stop that NPC being smart-locked? The entire faction/threat axis depends on the
answer.

**Do this**

1. Find **two NPCs of the same kind standing close together**. Enemies who move a lot are useless
 here.
2. With the overlay closed, aim at one and press the `KSTP: pin look-at target` hotkey.
3. Open the overlay. In panel 2, leave class `Chest` and modifier `Multiplier`, value `1000`.
 (The quick buttons are `10` / `100` / `1000` / `10000`.)
4. Read the line `target ... current value = ...`. **If it reads `0.0000`**, a `Multiplier` cannot
 move it - click `Additive` on the modifier row. If `Additive` also leaves the reported value
 unchanged, that stat is not defined on NPCs at all, and E-STAT is **FAIL**. Record it and move
 on: that is a real answer, not a broken test.
5. Press **`APPLY to target`**. The panel prints `last apply: before -> after`. The modifier
 landed only if that pair differs.
6. Close the overlay. Look at the sky for three seconds to drop any lock you already hold, then
 holster and re-draw. Aim at the modified NPC. Look at the sky again. Aim at its neighbour.
7. Press **`CLEAR ours`** and confirm the modified NPC goes back to normal.

**PASS** = the modified NPC's lock never completes while the neighbour locks normally.
**FAIL** = the stat value moved but both NPCs lock identically - the native handler reads
weapon-side stats only.
**INCONCLUSIVE** = the stat value would not move at all *and* you could not tell whether the
modifier reached the object.

A moved number with no visible effect is **FAIL**, not PASS. That distinction is the whole point
of this experiment.

**False-negative trap: you may have nothing to multiply.** If your weapon already locks almost
instantly - high-level smart gun, close range - then multiplying a near-zero lock time by a
thousand still lands the lock inside a frame or two, and both NPCs look identical. Before you
record a FAIL: back off to double the distance, and try a low-level unmodded smart weapon with a
slow base lock time. The lab does *not* print the weapon's base lock time, so you have to judge
this by feel - establish what "normal" feels like on the unmodified neighbour first.

**Second trap: you had a lock already.** Once a lock is established the game tends to keep it.
Look at the sky between every single attempt.

`RemoveAllModifiers` is a blunt escape hatch: it strips *all* modifiers of that stat from the
target, including any the game itself put there. Use it only to unstick a confused test, never as
part of a measurement.

---

### 2. E-TRACK - weapon-side component classes

Section **3. E-TRACK -- weapon-side component tracking**.

**Question:** does the native handler re-read `SmartGunTrack*Components` live, or only when the
weapon handler latches on draw?

**Do this**

1. Get into a fight and hold ADS so the small per-component boxes are visible on an NPC.
2. Press the `KSTP: E-TRACK zero head+chest` hotkey.

**PASS** = the head/chest boxes disappear immediately, no holster, no re-equip.

If they only disappear after you press **`cycle smart-gun handler`** (which queues
`EnableSmartGunHandlerEvent` off, then on again 0.6 s later - the same event
`vehicleTransition.script` uses), record **PASS** with the note `needs re-latch`. That still sets
`KSTPGate.LiveStatReread`, and tells `Enforcement/BodyPart.reds` it must cycle the handler after
every change.

If nothing happens either way, the setting never applied at all. That is a broken setup, not a
result - check the log panel and re-run.

**Trap: do not test a value that was already zero.** The panel lists the current values for Head,
Chest, Leg, WeakSpot and Mechanical through both candidate stats objects. Most smart weapons ship
with head tracking already off. Pick something non-zero; Chest is the safe pick. The
per-class buttons are `HEAD -> value`, `CHEST -> value` and `LEG -> value`, driving whatever is
in the `value` slider (quick buttons `0` and `-100`). `RESTORE ALL` removes them.

**Which stats object?** The `stats object:` row switches between `itemData`
(`weapon:GetItemData():GetStatsObjectID()` - what the vanilla Kiroshi cyberware effector targets)
and `entity` (`weapon:GetEntityID()`). Both columns are printed side by side. If applying to one
moves the boxes and the other does nothing, note which: that decides which `StatsObjectID`
`Enforcement/BodyPart.reds` writes to.

---

### 3. E-IGNORE - the targeting ignore list

Section **4. E-IGNORE -- targeting ignore list**.

**Question:** does `TargetingSystem.AddIgnoredLookAtEntity` reach the smart-lock pipeline, or only
the look-at / scanner channel?

Buttons: `ADD current target`, `REMOVE current target`, `CLEAR ALL`. The panel shows how many
entities are currently on the list and whether the current target is one of them.

Run it twice and report both halves:

- **(a)** `ADD current target` while you are *not* locked onto it. Can the smart gun still
 acquire it?
- **(b)** `ADD current target` while you are *already locked* onto it. Does the lock break, or
 hold until you look away?

**PASS** = the ignored NPC is skipped by smart lock while its neighbours still lock. Put the
answer to (b) in the report note either way: "new acquisition only" and "breaks existing locks"
are different features and the mod would use them differently.

**Watch the scanner too.** Two failures look identical from the gun's point of view and mean
completely different things:

- scanner still highlights the NPC, gun still locks it: the ignore never applied at all;
- scanner **stops** highlighting it but the gun still locks it: the ignore applied perfectly and
 the smart gun simply does not consult that list. That is a genuine, informative FAIL and it
 settles the question for good.

**The instigator trap is already handled.** The list is keyed on *(instigator, ignored entity)*,
not on the entity alone, and passing anything but the player is a silent no-op. The lab always
passes `Game.GetPlayer()` (`experiments.lua`, `Exp.ignoreAdd`), so you cannot get this wrong from
here - but it is the reason a hand-rolled console test of the same call usually "fails".

Nothing here touches your save; the list lives in memory only. Still, press `CLEAR ALL` before
you quit.

---

### 4. E-FILTER - script-side target filter

Section **5. E-FILTER -- script-side target filter**. This one has a **control step and you must
run it first**.

1. Press **`call ProcessLookAtFilter directly`**. This calls the native entry point with a
 `TargetFilter_Script` instance and checks whether the observed `Filter()` callback fires at
 all. The counters line (`PreFilter` / `Filter` / `PostFilter`) is the readout.
2. Only if the control fires, press **`RegisterLookAtFilter`** and play for ten seconds.
 `UnregisterLookAtFilter` takes it back off.

| CONTROL | LIVE | verdict |
| --- | --- | --- |
| fired | fired | **PASS** - script-side filtering is real |
| fired | silent | **INCONCLUSIVE** - the registration path is the problem, not the concept |
| silent | - | **INCONCLUSIVE**, not FAIL - a silent control proves the hook is wrong, not the game |

**Stated limitation.** CET's `NewProxy` builds an `IScriptable`-derived proxy and cannot declare a
subclass of the native class `TargetFilter_Script`, so Lua cannot supply its own `Filter()` body.
The rig therefore *observes* the base class's `PreFilter` / `Filter` / `PostFilter` and counts
invocations. That is enough to decide the lead, not enough to write a real filter.

If the control fires and you want a real filter body, copy `redscript_probe/KSTPFilterProbe.reds`
into `r6/scripts/`, restart, and drive it from the CET console as documented at the top of that
file.

---

### 5. E-AIMASSIST - the ten-minute disproof

Section **6. E-AIMASSIST -- preset swap (expected null result)**.

**Expected result: nothing happens.** Aim assist and smart-gun tracking are separate systems, and
confirming that in ten minutes is worth more than a week of speculation. Recording it as FAIL is
the useful outcome - it closes the lead.

Press **`Off`** (the preset buttons are `Off`, `Light`, `Standard`, `Heavy`), then immediately
check the `current AimAssistConfigPreset:` readback line and aim at an NPC. `RESTORE original`
puts back the preset captured before the first swap.

**Caveat the panel repeats:** `PlayerPuppet.ApplyAimAssistSettings` re-applies the vanilla preset
whenever the aim-assist state changes - entering ADS, mounting a vehicle, drawing a melee weapon.
Judge within a second or two without changing state. If the readback line has already reverted,
the preset never held and the result is **INCONCLUSIVE**, not FAIL.

---

## Recording a verdict

Every panel ends with the same row: **`PASS` / `FAIL` / `INCONCL` / `reset`**. Press one. That
sets the verdict inside the lab and nothing else - it does not touch the game or the mod.

Then section **7. REPORT / LOG / TEARDOWN** > **`WRITE REPORT`**. That writes

```
bin\x64\plugins\cyber_engine_tweaks\mods\kstp_lab\kstp_lab_report.txt
```

containing every verdict, the auto-collected evidence lines, the E-FILTER counters, the gate
mapping and the last 60 log lines. Paste the whole file back if you want help interpreting a
result. A rolling transcript is also appended to `kstp_lab_log.txt` beside it.

### Then turn the gate on, in Mod Settings

Pause menu > Settings > Mods > **Kiroshi Targeting Protocol** > the experiments category. Three
toggles, all off by default:

| Report line | Mod Settings toggle | What it unlocks |
|---|---|---|
| `KSTPGate.FactionAxisEnabled <- E-STAT` | faction axis | `Enforcement/Faction.reds` may write suppression modifiers to world NPCs, so a protocol can actually refuse civilians instead of only labelling them |
| `KSTPGate.LiveStatReread <- E-TRACK` | live stat re-read | protocol changes are believed to take effect immediately instead of from the next draw |
| `KSTPGate.IgnoreListWorks <- E-IGNORE` | ignore list | recorded for now; nothing in the shipped feature set depends on it yet |

E-FILTER and E-AIMASSIST set no gate. They exist to kill or confirm a design lead, and their
verdicts live in the report only.

Set each toggle to match what you actually saw. Leave anything you did not run, or were unsure
about, **off**. Restart the game so the gates apply cleanly.

---

## Safety

Everything this rig mutates is tracked and unwound:

- stat modifiers - removed with the same `gameStatModifierData` handle that was added;
- ignore-list entries - `RemoveIgnoredLookAtEntity` for every entity added;
- filter ticket - `UnregisterLookAtFilter`;
- aim-assist preset - restored to the value captured before the first swap.

Teardown runs on `onShutdown` and on **`PANIC: restore everything`** (button in section 7, and a
hotkey). The `outstanding mutations:` line in section 7 tells you at a glance whether anything is
still applied.

Stat modifiers applied to a *world NPC* have no save-restore path of their own. If the game
crashes with modifiers applied they die with the session - but reload the save rather than
trusting that, and never leave E-STAT applied when you stop testing.
