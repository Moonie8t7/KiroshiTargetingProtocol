# 0014. The tracked set is bounded and seeded

## Status

Accepted.

## Context

`KSTPFactionSystem` keeps `m_known`, the set of puppets the proactive half of enforcement will
decide on its next sweep. Its purpose is to put a verdict in place *before* a lock can form, which
the reactive per-frame path in `OnSmartGunParams()` cannot do: by the time a target appears in
`SmartGunParams` the lock is already forming, and a time-to-lock modifier cannot undo a lock that
has completed (ADR 0003).

The original design filled that set from the spawn hook and pruned it in `SweepKnown()`. Two
properties of that arrangement turned out to be defects rather than details.

**The set was never bounded.** `SweepKnown()` is the only pruner, and it is reachable only from
`KSTPFaction.Reevaluate()`, which `KSTPPolicySystem.Reapply()` calls on the armed branch alone. An
unarmed player therefore prunes nothing while `OnNPCSpawned` keeps recording. Membership was
tested with `ArrayContains`, a linear scan, so the per-spawn cost rose with everything ever seen.

A session on 18 August 2026 measured the consequence:

```
00:41:43  sweep: 268 live NPC(s), 599 streamed out     last prune of the session
00:51:39  reapply(loadout): armed=false                last mod activity
00:52:40  spawn hook: 11200 NPC(s) seen
00:57:25  spawn hook: 11400 NPC(s) seen
00:58:00  spawn hook: 11600 NPC(s) seen
00:58:33  log ends                                     process died
```

Seventeen minutes unarmed with no prune, at roughly six spawns per second, each paying a scan of
everything accumulated since. Earlier sessions reached 200 to 2,400 spawn-hook hits and ended
before the cost mattered; the defect was duration-dependent and had simply never been provoked.

**The set did not survive a load.** The spawn hook fires as an NPC streams in, which for every
NPC already loaded happened in a previous session, so a load leaves the set empty. Play confirmed
the effect: after loading, the first NPC aimed at locked normally, and only after looking away and
back was it refused, once the reactive path had caught up.

Persisting `m_known` was considered and rejected. `EntityID` is two different things: a static ID
is a baked world-node reference and stable across sessions, while a runtime-spawned ID is not, and
the ambient population is overwhelmingly the second kind. Vanilla marks every live-NPC ID
collection unsavable, `preventionSystem.script:4-5` and `securitySystemController.script:112-115`
among them, and saves only static or unique entities. This project already reached the same
conclusion for the two ledgers that *are* persistent: `OnRestored()` discards them, because a saved
ID ledger is a claim about a world that no longer exists. Persisting a third would also make the
unbounded growth permanent, riding in the save for players who later uninstall.

## Decision

`m_known` is a bounded working set, not a spawn history.

**It is seeded from the world.** `SweepKnown()` calls `SeedKnown()` first, which fills the set from
`GameObject.GetEntitiesAroundObject(radius, TSF_NPC())`: the same `TargetingSystem` registry the
smart gun draws its own candidates from, filtered to alive puppets excluding the player. Coverage
therefore tracks the threat surface rather than spawn order, and does not depend on having
witnessed a spawn.

**It is capped.** `KnownCap()` is 512, set against measured live counts of 9 to 268 NPCs per
sweep. `TrackKnown()` refuses beyond it rather than growing.

**The spawn hook records only while armed.** Recording while unarmed bought coverage that
`SeedKnown()` now provides from the world directly.

**A recovery seed covers the already-armed load.** A load that restores the player holding the
weapon produces no arm transition and so no sweep. `ReevaluateTracked()` treats an empty working
set as that signature and sweeps once, behind a cooldown so a barren area cannot re-query twice a
second.

**The radius is clamped above zero.** `GetEntitiesAroundObject` sets
`filterObjectByDistance = range > 0.0`, so a non-positive range disables its own distance filter
and returns the entire registry. That is the world sweep this system refuses to perform, and the
clamp is what prevents a mistuned setting from causing it.

## Consequences

Per-spawn cost is bounded by `KnownCap()` instead of by session length, which removes the
quadratic. Enforcement now has a verdict in place for nearby NPCs immediately after a load rather
than after the reactive path catches up.

Preventive reach is bounded in exchange. Beyond `SeedRadius()`, or past the cap in a crowd, an NPC
gets no verdict until it reaches the lock list, where `OnSmartGunParams()` decides it as before.
The reactive path remains the backstop for everything the weapon can actually see, so the cap
costs pre-emption, never correctness.

The seed applies no line-of-sight test. `TargetingSet.Complete` carries no frustum or LOS
restriction, so the set includes NPCs through walls within the radius. Route A is target-scoped and
world-wide, so this widens its allied-NPC collateral slightly against the lock-list path. That is
the accepted cost of deciding before a lock forms.

`SeedRadius()` is 80 metres, a tuning default rather than a value derived from any vanilla
constant. No cited figure establishes the smart gun's acquisition range, and the cap rather than
the radius is what bounds the work. A measured acquisition range would justify replacing it.
