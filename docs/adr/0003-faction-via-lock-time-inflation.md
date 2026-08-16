# 0003. Faction denial by lock-time inflation

## Status

Accepted

## Context

The faction axis needs to treat one NPC differently from another: engage gangers, refuse
civilians. Nothing in the acquisition pipeline is patchable from redscript (ADR 0001), so denial
has to be expressed through something the native code already reads.

Three mechanisms were available.

| Mechanism | Scope | Verdict |
|---|---|---|
| Toggle `SmartGunTrack*Components` on the target | Entity-global | Rejected. The component flags are read by systems other than the smart gun. Clearing them on a world NPC breaks that NPC's own aiming and interferes with quickhack targeting. |
| `TargetingSystem.AddIgnoredLookAtEntity` | Observer-scoped | Rejected. Smart-gun acquisition does not consult this list. It governs the LookAt channel only. |
| Inflate `SmartGunTimeToLock*ComponentMultiplier` on the target | Target-scoped | Accepted. The native lock timer reads the multiplier from the target NPC's stat object. |

The ignore list was the preferred shape on paper: a binary veto, keyed on
`(instigator, ignored entity)`, with a vanilla call site in
`vehicleComponent.script:2930`, and no stat state left on world entities. It does not reach the
smart gun.

## Decision

Deny a target by adding a `SmartGunTimeToLock*ComponentMultiplier` modifier to that NPC's
`StatsObjectID`, using the suppression factor in `KSTPStats.SuppressionMultiplier()`. The lock
timer for the denied class stretches far past any realistic aim duration, so the target holds at
`Locking` and never reaches `Locked`.

`Enforcement/Faction.reds` owns the modifiers and the record of every entity touched.

## Consequences

**It prevents a lock. It cannot undo one.** The multiplier only stretches a timer that has not
finished. A target already at `Locked` stays locked until the gun drops it for its own reasons.
The permit decision therefore has to land before the lock completes, which puts a hard latency
requirement on classification and enforcement: reactive application driven off a delayed
blackboard listener can lose the race, and a lock slips through.

**It is target-scoped, not observer-scoped.** The modifier sits on the NPC, so it applies to every
smart weapon in the world, not only the player's. An allied NPC firing a smart weapon at a target
KSTP has denied is impaired the same way the player is. An observer-scoped mechanism would not
have this cost, and the one candidate for that shape does not work.

**The target still draws a bracket.** Suppression acts on the lock timer, not on candidacy, so a
denied NPC still appears in the smart-gun UI list and still shows a targeting bracket that never
fills. The IFF overlay marks it `REFUSE` so the state is legible rather than confusing.

**State has to be restored.** Stat modifiers on world entities have no save-restore path of their
own. Every touched entity is tracked and its modifiers removed on unload, on protocol change, and
on teardown (CONTRACT rule 4).

**Cost scales with the number of denied NPCs**, since each one carries its own modifiers. This is
what makes the civilian default in ADR 0005 load-bearing.
