# KSTP - architecture

How the mod is laid out, which layer is allowed to do what, and how a change made in the
settings menu reaches the game.

This document names the interface each module must provide, the shape those interfaces sit
in, and the ownership rules that keep them apart.

---

## Module map

```text
                          +-----------------------------+
                          |            Input            |
                          |   Input/Hotkeys.reds        |
                          |   KSTPInputListener         |
                          +--------------+--------------+
                                         |
                    CycleNext()          |   KSTP_SetOverlayHold()
                                         v
+----------------------------------------------------------------------------+
|                                   Core                                     |
|                                                                            |
|  Core/Types.reds        KSTPProtocol, KSTPClassification, KSTPStats        |
|  Core/Log.reds          KSTPLog                                            |
|  Core/Gate.reds         KSTPGate, KSTPGateConfig                           |
|  Core/Classifier.reds   KSTPClassifier, KSTPClassifierCache               |
|  UI/Settings.reds       KSTPSettings, KSTPSettingsSystem  (module KSTP.Core)|
|                                                                            |
|  Core/Policy.reds       KSTPPolicySystem   <-- pushes every accepted       |
|                                                change into Enforcement     |
+---------------------+------------------------------------+-----------------+
                      |                                    ^
      Apply / Clear   |                                    | Classify / Permits
                      v                                    | GetActive / IsArmed
+----------------------------------------+     +-----------+------------------+
|              Enforcement               |     |              UI              |
|                                        |     |                              |
|  Enforcement/BodyPart.reds             |     |  UI/Overlay.reds             |
|    KSTPBodyPart / KSTPBodyPartState    |     |    KSTPIFFOverlay            |
|    writes the HELD WEAPON stats object |     |    KSTPIFFLabel              |
|                                        |     |    KSTPOverlayConfig         |
|  Enforcement/Faction.reds              |     |  UI/Localization.reds        |
|    KSTPFaction / KSTPFactionSystem     |     |  read-only against the game  |
|    writes the TARGET NPC stats object  |     +------------------------------+
+--------------------+-------------------+
                     |
                     v
              StatsSystem.AddModifier / RemoveModifier
```

Dependency direction is one way. Core knows nothing about UI or Input. Enforcement imports
`KSTP.Core` and is imported by two modules. `Core/Policy.reds` takes it through an
`@if(ModuleExists("KSTP.Enforcement"))` guard, so a load order where Enforcement failed to
compile degrades to "policy tracked, nothing applied". `UI/Overlay.reds` imports it
unguarded, to hand the per-frame smart-gun payload to `KSTP_PushSmartGunParams()`, which is
the only delivery route the faction axis has (ADR 0012).

`UI/Settings.reds` sits under `UI/` but declares `module KSTP.Core`. Gate, Policy and both
Enforcement files need to read settings, and making them depend on a UI module for a bool
would invert the layering.

---

## Ownership

| Layer | Owns | Must not |
|---|---|---|
| Core | Types, the active protocol, classification, the experiment gates, settings | Write any stat, modifier, or entity state |
| Enforcement | Every write into the game, and the ledger that undoes it | Decide policy, read the settings menu directly |
| UI | The IFF overlay, the item display strings and the Mod Settings surface | Mutate a world entity or a stat |
| Input | Two key bindings and one blackboard bool | Call Enforcement, hold policy state |

### Core

`Core/Types.reds` is dependency-free and loaded first. `KSTPStats.TrackStatFor()` and
`KSTPStats.TimeToLockStatFor()` are the only mapping from the mod's `KSTPTargetClass` to the
real `gamedataStatType` values the native handler reads, so both Enforcement paths go through
them and nothing else hard-codes a stat name.

`Core/Policy.reds` holds `KSTPPolicySystem`: the six presets, which one is active (the single
persistent field, `m_activeProtocolId`), and `IsArmed()`, which is true only when the mod's
cyberware is installed and a smart weapon is in the right hand. It pushes state into
Enforcement and never touches a weapon or an NPC itself.

#### Cyberware tier

The implant ships as eleven TweakDB records covering the vanilla quality ladder. Reading which
one is installed is `Core/Policy.reds` work and nobody else's:

| Function | Returns |
|---|---|
| `KSTP_CyberwareTierOf(id)` | Tier 1 to 5 for one item, 0 when the item is not the mod's. Plus grades count as their base tier |
| `KSTP_CyberwareTier(owner)` | Highest tier across every cyberware equipment area, 0 when none is installed |
| `KSTP_HasCyberwareInstalled(owner)` | The same value as a `Bool` |

`KSTPPolicySystem` caches the walk in `m_cyberwareTier` and refreshes it on the equipment hooks
at the foot of the file, because cyberware changes only at a ripperdoc. Two readers consume the
cache, both on the system:

| Reader | Requires | Effect while it is false |
|---|---|---|
| `IsArmed()` | tier >= 1, and a smart weapon in the right hand | Nothing is applied to the weapon; the overlay reads `OFFLINE` |
| `FactionAxisAvailable()` | tier >= 1, whichever grade that is (ADR 0009) | Targets are classified and labeled, and none are suppressed |

`GetCyberwareTier()` returns the cached number for callers that want the tier itself rather than a
verdict.

The eleven record names are pinned in `KSTP_CyberwareTierOf()` and authored in
`src/r6/tweaks/KSTP/cyberware.yaml`. A `TweakDBID` literal is a compile-time hash, so a name that
drifts between the two files compiles clean, loads clean, logs nothing, and makes that grade of the
implant inert.

**Body-part unlocks are data, not script.** Which component classes a tier grants comes from the
stat group each record points at in the yaml, applied through the same `ApplyStatGroupEffector`
path the whole implant already uses. No redscript branches on tier to decide a class, and
Enforcement's view is unchanged by the ladder: it refuses classes the active protocol denies, on
top of whatever the installed record enabled. Nor does script read which grade is installed:
`IsArmed()` and `FactionAxisAvailable()` both test only that one is (ADR 0009), and the
Intelligence attunement the ladder adds from tier 3 is data as well.

`Core/Classifier.reds` is pure read. `KSTPClassifier.Classify()` runs once per tracked
candidate per frame from the overlay, so anything with a side effect there would fire at
frame rate. `KSTPClassifier.Permits()` is the policy predicate: protocol plus classification
in, verdict out. It does not consult `KSTPGate`, because the gate decides whether Enforcement
may act while the overlay colors by verdict on every install.

`Core/Gate.reds` records experiment results rather than preferences. `KSTPGate.Snapshot()`
exists for callers that would otherwise allocate a config object per tracked target per frame.

### Enforcement

Enforcement is the single owner of the restore-what-you-mutate rule (CONTRACT hard rule 4).
Two ledgers implement it:

| Ledger | File | Holds |
|---|---|---|
| `KSTPBodyPartState.m_applied` | BodyPart.reds | Every modifier handed to `StatsSystem` for the weapon, plus the `StatsObjectID` it went to |
| `KSTPFactionSystem.m_statMods` / `m_statModOwners` | Faction.reds | Every modifier applied to a world NPC, index-parallel with the entity it went on |

Both use `StatsSystem.RemoveModifier` with the exact handle, never `RemoveAllModifiers`, which
would strip another mod's or a quest effector's modifier off the same stat.

### UI

`UI/Overlay.reds` draws one label per tracked candidate from the live
`UI_ActiveWeaponData.SmartGunParams` payload (`blackboardDefinitions.script:1601`,
`smartGunUIParameters`, `orphans.script:54420-54460`). It registers no listener for that
variable: delivery is a `@wrapMethod` on
`CrosshairGameController_Smart_Rifl.OnSmartGunParams`, the host controller's own handler,
because a `RegisterDelayedListener*` from outside an ink game controller never fires
(ADR 0012). The same wrap forwards the payload to the faction axis. The overlay hosts on
`CrosshairGameController_Smart_Rifl`, which only exists while a smart weapon's crosshair is
up, and it removes its widgets symmetrically in `Detach()`.

`UI/Localization.reds` registers the coprocessor's display strings for the `LocKey` tokens
`src/r6/tweaks/KSTP/cyberware.yaml` cites, through Codeware's localization provider behind an
`@if(ModuleExists("Codeware.Localization"))` guard. Codeware is therefore a soft dependency
for presentation: without it the item name renders blank and no gameplay path changes
(ADR 0008).

### Input

`Input/Hotkeys.reds` registers a vanilla `GameObject.RegisterInputListener`
(`gameObject.script:152`) for two actions. The cycle key calls
`KSTPPolicySystem.CycleNext()`, then `KSTPSettingsSystem.SyncMenuProtocol()`, so the menu's
active-protocol box reports what the hotkey selected (ADR 0010). The overlay key writes one
bool onto the `UI_System` blackboard through the `@addField(UI_SystemDef) KSTPOverlayHold`
channel, which the overlay reads. The overlay never names the input module; the input module
names `KSTP.UI` only to print the current visibility mode in its trace.

---

## The two enforcement paths

Smart-gun target acquisition is native end to end. `TargetingSystem` is
`abstract final importonly` (`orphans.script:22381`), and no per-candidate veto is reachable
from redscript. What exists instead are two stat surfaces the native handler reads.

### Path 1: weapon-side body-part stats

Decided in `KSTPBodyPartState.ApplyProtocol()` (Enforcement/BodyPart.reds), one pass over
`KSTPBodyPart.AllClasses()`, acting only on classes the active protocol refuses.

| Lock policy | Stat written | Modifier | Effect |
|---|---|---|---|
| Strict | `KSTPStats.TrackStatFor(cls)` | `Multiplier` 0.0 | The class is not tracked at all |
| Preferred | `KSTPStats.TimeToLockStatFor(cls)` | `Multiplier` 1000.0 | The class stays lockable but loses every lock race |

`Preferred` falls back to an `Additive` modifier when the base value reads as zero, because a
`Multiplier` against a neutral zero lands nowhere.

Vehicle is the one class that takes the `Strict` treatment under either policy. Lock-time
inflation was measured to do nothing to a car, so a denied Vehicle class is hard-denied on
`SmartGunTrackVehicleComponents` whatever the lock policy says (ADR 0013).

The write target is the held weapon's item stats object,
`weapon.GetItemData().GetStatsObjectID()`, resolved by
`KSTPBodyPart.ResolveWeaponStatsObject()`. That is the path vanilla resolves
`applicationTarget "Weapon"` to (`effector.script:33`), and the path
`Items.KiroshiOpticsFragment1` uses to put `SmartGunTrackLegComponentsModifier` on the held
gun through `Prereqs.SmartWeaponHeldPrereq`. The vanilla precedent is the reason this axis is
safe to build on.

The stats object is rebuilt whenever the weapon is drawn, so `KSTPBodyPartState` registers an
`AttachmentSlotsScriptCallback` on `AttachmentSlots.WeaponRight`
(`KSTPBodyPartSlotCallback`) and re-applies on equip, clears on unequip. That mirrors
`ApplyStatGroupEffector`, which is how vanilla reacts to weapon changes, and it costs no
`@wrapMethod`.

This axis decides where on an already-valid target the lock lands. It does not decide which
targets are valid: disabling every body-part class does not stop targeting, because the
handler falls back to a raw head slot (`weapon.script:1526`). The one measured exception is
the Vehicle class: with `SmartGunTrackVehicleComponents` zeroed, cars stopped reaching the
lock list at all, which is why vehicle exclusion lives on this axis (ADR 0013).

### Path 2: target-side faction suppression

Decided in `KSTPFactionSystem.Decide()` (Enforcement/Faction.reds), which calls
`KSTPClassifier.Classify()` and then `KSTPClassifier.PermitsCoded()`. A refused, live,
non-player puppet goes to `Suppress()`; anything else goes to `Release()`, a refused vehicle
included. The verdict on a vehicle is still computed, because the overlay labels the car from
it, but the exclusion itself belongs to the class mask (ADR 0013).

`Suppress()` writes `SmartGunTimeToLock*ComponentMultiplier` at
`KSTPStats.SuppressionMultiplier()` onto the target NPC's own stats object,
`Cast<StatsObjectID>(entityID)`. Verified working on game 2.31 against a `ScriptedPuppet`,
and only against one: the suppressed NPC holds at `gamesmartGunTargetState.Locking`
(`orphans.script:8702`) while its neighbors reach `Locked`, and the identical inflation on a
vehicle changes nothing (ADR 0013).

`KSTPFactionSystem.WantedClasses()` returns all seven classes unconditionally. A faction
refusal means the target may not be locked at all, so it closes every avenue, the raw head
slot the handler falls back to included; `lockPolicy` governs the weapon-side mask and is not
read on the target side (ADR 0013). `SameClassSet()` is consequently always true, and
`m_appliedClasses` survives as the flag recording that a batch has been populated.

The axis is gated three ways, and all three must hold before an entity is suppressed:

| Gate | Question it answers |
|---|---|
| `KSTPGate.FactionAxisEnabled()` | Does the mechanism work on this build at all |
| `KSTPPolicySystem.FactionAxisAvailable()` | Is a coprocessor installed, at any grade |
| The active protocol's `factionFilterEnabled` | Has the player asked for faction filtering |

With any of them off, faction data is still classified and displayed; only the write stands down.
None of the three subsumes another, which is why they sit beside each other: an implant on a
build where the mechanism is unproven is still refused by `KSTPGate`, and a proven mechanism
with no coprocessor installed suppresses nothing.

Two facts constrain the design and are not worked around:

- The modifier lives on the target, not on the observer. Any NPC carrying a smart weapon is
  impaired against exactly the targets the player's protocol refuses. There is no observer
  parameter on a stat.
- The mechanism prevents a lock. It cannot undo one. That is why the decision runs
  per candidate on every `SmartGunParams` write, ahead of the throttle, rather than only in
  the periodic bookkeeping pass.

`TargetingSystem.AddIgnoredLookAtEntity` is present as a second route behind
`KSTPGate.IgnoreListWorks()`, which ships off. That call does not affect smart-gun
acquisition; it is LookAt-scoped, and the smart-gun handler does not consult it.

### Who drives each path

| Path | Driver | Fires on |
|---|---|---|
| Body part | `KSTPPolicySystem.Reapply()` | Attach, protocol change, loadout change, settings change |
| Body part | `KSTPBodyPartSlotCallback` | Weapon equipped or unequipped |
| Faction | `KSTPFaction.OnNPCSpawned()` | Puppet attach (Codeware `Entity/Attach`, or the `@wrapMethod(ScriptedPuppet) OnGameAttached` fallback) |
| Faction | `KSTPFactionSystem.OnSmartGunParams()` | Every `SmartGunParams` payload the crosshair handles, forwarded by `UI/Overlay.reds` (ADR 0012) |
| Faction | `KSTPFaction.Reevaluate()` | Attach, protocol change, loadout change, settings change |

`Reevaluate()` walks two sets and never sweeps the world: the entities already touched, which
have to be restored, plus the entities on the live lock list, which are the only ones that can
be locked right now. `SweepKnown()` covers the proactive half, re-deciding every NPC the spawn
hook recorded while the player was unarmed.

---

## Data flow: a settings change

```text
  player closes the pause menu
            |
            v
  PauseMenuGameController.OnUninitialize          @wrapMethod, UI/Settings.reds
            |
            v
  KSTPSettingsSystem.RefreshFromMenu()
            |
            +-- Reload()          new KSTPSettings / new KSTPHotkeys
            |                     (Mod Settings has already patched the class defaults)
            +-- m_revision += 1
            |
            +-- Reconcile()
            |     for each protocol:
            |       RestoreBaseline(p)     put the preset back to how Policy built it
            |       settings.ApplyTo(p)    stamp the menu on top, in place
            |     if the menu's protocol pick moved: policy.SetActive(id)
            |     policy.OnSettingsChanged()
            |            |
            |            v
            |     KSTPPolicySystem.Reapply("settings", force = true)
            |            |
            |     armed? +-- yes --> KSTPBodyPart.Apply(gi, active)
            |            |           KSTPFaction.Reevaluate(gi)
            |            |
            |            +-- no ---> KSTPBodyPart.Clear(gi)
            |                        KSTPFaction.ClearAll(gi)
            |
            +-- Broadcast()       KSTPSettingsChangedEvent on the player and the UI system
```

Three details make this correct rather than merely plausible.

`RestoreBaseline` before `ApplyTo` exists because `ApplyTo` mutates the preset objects in
place. Without a pristine snapshot, turning an override back off would leave the preset
permanently rewritten. `KSTPProtocolBaseline` is captured the first time a protocol is seen,
before anything has had a chance to mutate it.

`Reapply` is forced here. Its normal guard keys on the `(armed, protocolId)` pair, and a
settings edit moves neither: `ApplyTo` rewrites the contents of the active `KSTPProtocol` and
leaves its id alone. Any caller that mutates a protocol rather than switching to a different
one must pass `force = true`.

A forced push is not a stacking push. `KSTPBodyPart.Apply` removes every modifier it
previously applied before applying a new one, and `KSTPFaction.Reevaluate` re-decides per
entity against the current ledger, so a duplicate call costs one remove and re-add of
identical modifiers.

`Reconcile()` also runs from `KSTP_ReconcileSettings()` in `Input/Hotkeys.reds` when the
player puppet attaches, because `KSTPSettingsSystem` and `KSTPPolicySystem` attach
independently and either order has to end with the presets reconciled.

`KSTPPolicySystem.GetGeneration()` is bumped on every accepted change, for consumers that
would rather compare an `Int32` than subscribe to `KSTPSettingsChangedEvent`.

---

## Scriptable systems

Redscript has no static class fields, so all mod-global state lives on `ScriptableSystem`
instances, registered under their fully qualified module names.

| System | RTTI name | Holds |
|---|---|---|
| `KSTPPolicySystem` | `KSTP.Core.KSTPPolicySystem` | Presets, active protocol id (persistent), armed state, cached cyberware tier |
| `KSTPSettingsSystem` | `KSTP.Core.KSTPSettingsSystem` | Live settings copy, preset baselines, revision |
| `KSTPClassifierCache` | `KSTP.Core.KSTPClassifierCache` | Per-entity immutable classification axes, hoisted player attitude agent |
| `KSTPBodyPartState` | `KSTP.Enforcement.KSTPBodyPartState` | Weapon modifier ledger, slot listener, last protocol |
| `KSTPFactionSystem` | `KSTP.Enforcement.KSTPFactionSystem` | Suppression ledger, the blackboard handle the lock list is polled through, known-entity set |

Every one of them clears its ledger on detach, through `OnPlayerDetach`, `OnDetach`, or both.
`KSTPFactionSystem` also clears on `OnRestored`, because a load drops every non-saved stat
modifier while the persistent ID ledger survives, and carrying stale IDs forward would be a
lie about world state.

---

## Rules that hold across modules

1. One writer per surface. The weapon stats object is written only by `KSTPBodyPartState`;
   world NPC stats objects only by `KSTPFactionSystem`.
2. Every write is ledgered with the exact `gameStatModifierData` handle, and removed with it.
3. Gate off means "be in the off state", not "do nothing". `KSTPFaction.Reevaluate()` with the
   gate off calls `ReleaseAll()`, and `KSTPFaction.ClearAll()` is ungated so a teardown cannot
   refuse to run because the feature is already off.
4. Never refuse on ignorance. An unreadable attitude, an unknown affiliation or a missing
   record abstains and permits, so a partial read never blanks the world.
5. Nothing in the mod is fatal. Every optional dependency is guarded with
   `@if(ModuleExists(...))`, every gated feature no-ops cleanly, and the mod is fully playable
   with every gate false.
