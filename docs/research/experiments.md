# Experiment results, game build 2.31

Three mechanisms were tested in game. Two work and carry the mod, one of them only against
puppets; one does not and is not used. These results decide what KSTP can claim.

Mechanism-level reference on how smart-gun targeting is wired is in `smart-gun-internals.md`.
Raw capture, including the full lab log and report, is in `docs/evidence/`:

| File | Contents |
|---|---|
| `docs/evidence/2026-08-16-lab-log.txt` | Timestamped stat before/after values and lab events |
| `docs/evidence/2026-08-16-lab-report.txt` | Lab report file as written by the CET rig |

Test environment: Cyberpunk 2077 build 2.31, GOG install carrying roughly 300 script mods and
2937 archives, CET v1.37.1, driven by `experiments/cet/kstp_lab`. The lab's own report file
records every verdict as `UNTESTED`; its PASS/FAIL buttons were never pressed. The verdicts below
come from the logged stat values, which are in the log, and from the HUD state transitions, which
are read off the lab's on-screen readout and transcribed here.

The `sweep:` and lock-list lines quoted below come from the mod's own redscript trace in later
in-game sessions rather than from the CET rig, as does the vehicle result in section 1. Those
sessions are recorded in ADR 0012 and ADR 0013; their logs are not in `docs/evidence/`.

---

## 1. Target-side lock-time inflation: works on puppets, not on vehicles

**Tested.** Whether a `SmartGunTimeToLock*ComponentMultiplier` modifier applied to a target's
`StatsObjectID` reaches the native smart-gun handler.

**Result on a `ScriptedPuppet`.** It does. Applying `SmartGunTimeToLockHeadComponentMultiplier` at
x1000 to a single NPC held that NPC at `Locking` indefinitely while unmodified NPCs in the same
encounter locked normally.

```
E-STAT apply NC Resident SmartGunTimeToLockHeadComponentMultiplier
       Multiplier 1000.00 | before=1.0000 after=1000.0000
```

Same NPC, same weapon, seconds apart:

```
mods=0   1. Locked   [LOCKED]  d=5.2m  bone=Head
mods=1   1. Locking            d=5.3m  bone=Head     lock never completes
```

`Locking` is `gamesmartGunTargetState = 2` and `Locked` is `3` (`orphans.script:8702-8708`). The
handler resolves the multiplier from the target's stats object.

**Result on a vehicle.** It does not. The same inflation on a car changes nothing measurable.
Instrumentation on a later session recorded the refusal firing 33 times against passing traffic
under the x1000 multiplier, and every one of those cars took a full lock at normal speed, in a
session where an NPC under the identical multiplier held at `Locking` and never completed. The
mechanism binds on a puppet's stats object and not on a vehicle's, so vehicle exclusion travels
the class mask instead: `Enforcement/BodyPart.reds` hard-denies the Vehicle class under either
lock policy, and `Enforcement/Faction.reds` releases a refused vehicle rather than suppressing it.
See ADR 0013.

**What it means for the implementation.**

- The faction and threat-class axes are enforceable per candidate puppet, in pure redscript. No
  RED4ext plugin is required.
- The mechanism is preventive only. It stops a lock from completing and cannot release a lock that
  has already completed, so enforcement must reach a candidate before its lock timer finishes. The
  live candidate list arrives on the UI tick (`smart-gun-internals.md` section 5), taken from the
  crosshair controller's own `OnSmartGunParams` rather than from a listener of the mod's own
  (ADR 0012), so a pass driven only by that payload is reactive and can lose the race; a lock that
  completes first stays. `Enforcement/Faction.reds` therefore also decides puppets proactively, at
  spawn and on every sweep, before a lock can form.
- Scope is the target, not the observer. An allied NPC carrying a smart weapon is impaired against
  a suppressed target too. This is a property of the mechanism, not a defect in the enforcement
  code, and is documented in `Enforcement/Faction.reds`.
- Every modifier is written onto a world entity that the mod does not own. Stat modifiers have no
  save-restore path of their own, so every touched entity must be tracked and restored on unload,
  on policy change and on teardown.

---

## 2. Weapon-side track-component stats: work, and are re-read live

**Tested.** Whether the handler re-reads the weapon's `SmartGunTrack*Components` stats while a lock
is in flight, or latches them when the weapon is drawn, and which stats object it reads.

**Result.** Re-read live. Zeroing the Head class moved an in-flight lock immediately, with no
holster and no re-equip.

```
E-TRACK SmartGunTrackHeadComponents  [itemData] Multiplier=0.0 : 4.000 -> 0.000
E-TRACK SmartGunTrackChestComponents [itemData] Multiplier=0.0 : 3.000 -> 0.000
```

```
mods=0   bone=Head       baseline, coprocessor active
mods=1   bone=Spine3     Head zeroed, lock falls to chest immediately
mods=3   bone=Head       Head and Chest zeroed, lock falls back to a raw head slot
```

Writes landed on `weapon:GetItemData():GetStatsObjectID()`. The weapon entity's own stats object is
the wrong target; the item-data object is what the handler reads, and it is the same object the
vanilla Kiroshi effector writes to (`core\gameplay\effector.script:31-38`).

**What it means for the implementation.**

- Protocol switching binds immediately. There is no need to bounce the weapon with
  `EnableSmartGunHandlerEvent` (`orphans.script:61871`) or to force a re-equip.
- All track-stat writes must target item data. Writing to the weapon entity is a silent no-op.
- **Disabling every class does not disable targeting.** With Head and Chest both zeroed the lock
  fell back to a raw head slot rather than refusing, matching the native fallback at
  `cyberpunk\items\weapon.script:1533`. A protocol that leaves a puppet with no enabled class does
  not refuse that puppet; it engages the head. "Do not engage this puppet" belongs on the
  target-side mechanism in section 1, not on the body-part axis.
- **Vehicle is the exception, by measurement rather than by that rule.** Zeroing
  `SmartGunTrackVehicleComponents` does keep a car off the lock list: across a full session after
  the class mask took the vehicle decision over, all 412 lock-list traces reported `0 vehicle(s)`.
  That is the one class where the weapon-side axis excludes a target, and it carries the exclusion
  because the target-side mechanism does not bind on a vehicle (ADR 0013).

### Supporting confirmations from the same runs

- The cyberware delivery path fires. Every class the installed grade unlocks reads `2.00` on the
  held weapon where vanilla ships `0`, sourced from `KSTP.Mod_TrackOn_*` (`stats.yaml`), while
  Chest `3`, Leg `2` and Mechanical `1` match the vanilla baseline. Which classes those are is the
  tier ladder: head at tier 1, weak spot at 2, breach at 3, vehicle at 4, and tier 5 unlocks
  nothing further but locks those four classes faster (`cyberware.yaml`, `stats.yaml`).
  `Prereqs.SmartWeaponHeldPrereq` resolves despite being absent from the script dump, and the
  `ApplyStatGroupEffector` path applies the group. A readback of `4.00` on an unlocked class is the
  group applied twice, which `reapplyOnWeaponChange: False` corrects: the prereq is itself an
  item-in-slot watch on `AttachmentSlots.WeaponRight`, so the flag added a second listener over the
  top of it.
- The capacity cost is charged through the `variants` list, not through a `statModifiers` entry:
  the implant carries `Variants.Humanity6Cost` at every grade.
- Teardown is reliable while the entity is still resolvable. Every removal pass logged
  `0 failure(s)` across dozens of applications, except the final teardown of the last session,
  which reported `TEARDOWN: 0 modifier(s) removed (1 failed)` against a modifier applied eight and
  a half minutes earlier. A removal that cannot land is a state the bookkeeping must tolerate,
  which is why `Enforcement/Faction.reds` drops the handles for an entity it can no longer resolve
  instead of calling `RemoveModifier` on it.
- Neutral NPCs are smart-lockable in vanilla. Targets reading `ATT=AIA_Neutral` reached `[LOCKED]`
  throughout. The engageable boundary is friendly, not hostile, so the attitude axis is only useful
  subtractively: it can withhold targets the gun would otherwise take, and cannot add targets the
  gun refuses.

---

## 3. The look-at ignore list: does not affect smart-gun acquisition

**Tested.** Whether `TargetingSystem.AddIgnoredLookAtEntity` (`orphans.script:22443`) removes an
entity from smart-gun target acquisition.

**Result.** It does not. With suppression routed exclusively through the ignore list, denied Tyger
Claws still reached `[LOCKED]` at 15.3 m, 17.0 m, 23.8 m and 25.4 m.

The entities were on the list. The sweep logged the split between the two routes:

```
sweep: 6 live NPC(s), 0 streamed out, suppression 0 -> statMod=0 ignore=3
sweep: 8 live NPC(s), 0 streamed out, suppression 5 -> statMod=0 ignore=5
```

`statMod=0` confirms the stat route was fully stood down and the ignore list was solely
responsible. Targets locked anyway.

The list is keyed on `(instigator, ignored entity)`, so passing anything other than the player as
instigator is a silent no-op and the most likely way to produce a false negative. The lab passes
`Game.GetPlayer()`.

**Conclusion.** The ignore set is LookAt-scoped. Its vanilla callers do not include weapon lock:

| Caller | Purpose |
|---|---|
| `cyberpunk\devices\core\deviceBase.script:3827`, `:3837` | Device interaction |
| `cyberpunk\player\psm\locomotionTakedown.script:13-24` | Takedowns |
| `core\components\scriptComponents\vehicleComponent.script:2938`, `:2945` | Mounted-vehicle self-ignore |

**What it means for the implementation.** The ignore route is not a substitute for the target-side
stat mechanism and must not be enabled in its place. Enabling it trades a working mechanism for one
that does nothing, because suppression clears the stat modifier before adding the entity to the
list. `KSTPGate.IgnoreListWorks()` is `false` in the compiled default and in `user.ini`.

The observer-scoped veto that would have avoided the allied-NPC collateral in section 1 does not
exist in redscript. The remaining route for the associated UX problem, a denied target drawing a
bracket that can never fill, is cosmetic: hide or restyle the widget through the crosshair
controller that `UI/Overlay.reds` already wraps.

---

## 4. The reusable trap: read the stat before calling it inert

`SmartGunTimeToLock*ComponentMultiplier` reads `1.0` on an NPC in vanilla, on Head and on Chest
alike, and every `Multiplier` modifier compounds on what the last one left. A probe that re-applies
its own modifier therefore climbs the float range in a few seconds and then stops moving, because a
saturated stat produces no further change in behaviour:

```
1.0 -> 1e3 -> 1e6 -> ... -> 1e33 -> 1e36 -> 340282346638528859811704183484516925440 (FLT_MAX)
```

Thirteen x1000 writes reached FLT_MAX; the ten writes after it logged `modifier applied but the
stat value did not change`. A test that begins on an already-saturated stat reports a working
mechanism as dead. Two rules follow for any stat probe in this codebase:

1. Read the current value before and after every write, and log both. A write that changes nothing
   is distinguishable from a write the handler ignores only if the before value is known.
2. Test the class that matches the bone actually being locked. `attachedBoneName` on
   `smartGunUITargetParameters` (`orphans.script:54438`) names it, and the HUD readout shows it.
   Suppressing Chest while the gun is locking Head proves nothing either way.
