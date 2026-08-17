# 0013. Each axis enforces its own question

## Status

Accepted. Supersedes the decision in [0011](0011-vehicle-refusal-and-overlay-visibility.md)
regarding vehicles; the correction 0011 makes to
[0006](0006-body-part-classes-cannot-exclude-targets.md) stands.

## Context

This mod has two enforcement axes. The class mask writes `SmartGunTrack*Components` on the weapon
and decides where a lock may land. The faction axis writes `SmartGunTimeToLock*` on the target and
decides whether a lock may form at all. [0003](0003-faction-via-lock-time-inflation.md) and
[0006](0006-body-part-classes-cannot-exclude-targets.md) establish that separation. Two defects
had crossed it in opposite directions.

**Vehicle exclusion was routed onto the faction axis.**
[0011](0011-vehicle-refusal-and-overlay-visibility.md) moved it there on the reasoning that the
class mask cannot exclude a target, which 0006 had proven. The reasoning was sound and the result
did not work. Instrumentation recorded the refusal firing 33 times against passing traffic:

```
vehicle seen: aff=Unaffiliated allowsVEHICLE=false permits=false
  [VEHICLE target class is off] -> SUPPRESS
```

Every one of those cars took a full lock at normal speed. In the same session, an NPC of an
unticked faction under the identical 1000x multiplier held at `Locking` and never completed.
Lock-time inflation binds on a puppet and does nothing to a vehicle. The mechanism 0003 validated
was never validated on this target type.

**Faction refusal was made to depend on the lock policy.** `WantedClasses` computed
`preferred || protocol.Allows(cls)`, so under `STRICT` a refusal covered only the classes the
protocol still permitted. The native handler falls back to a raw head slot when no enabled class
matches a candidate (`weapon.script:1526`), so a refusal that skipped a denied class left that
fallback open. A target-side decision was reading a weapon-side setting.

## Decision

Each axis answers only its own question, on the mechanism that works for it.

**Vehicle exclusion belongs to the class mask.** `Enforcement/BodyPart.reds` hard-denies the
Vehicle class whatever the lock policy says, zeroing `SmartGunTrackVehicleComponents` so the gun
does not acquire the car. `SOFT` is not a weaker refusal for this class; it was measured to be no
refusal at all. Vehicle is the only class carrying this exception.

`KSTPClassifier.Permits` still refuses a vehicle whose class is unticked. That verdict is what the
IFF overlay reads to label the car, and the refusal is honest whether or not this axis is the one
enforcing it. `Decide` releases vehicles rather than suppressing them, because applying a modifier
with no measured effect is cost without benefit.

**The faction axis covers every class.** `WantedClasses` returns all seven unconditionally. A
refusal means the target may not be locked at all, so it closes every avenue including the
fallback slot. `lockPolicy` is no longer read on the target side.

## Consequences

Vehicles are refused. Across an entire test session after the change, all 412 lock-list traces
reported `0 vehicle(s)`: the gun no longer offers a car as a candidate, so no downstream refusal
is required.

`PREFERRED` now has one exception and is otherwise unchanged. A player who unticks CHEST under
`PREFERRED` still sees chest components acquired and deprioritised, which is what the setting
promises. A player who unticks VEHICLE gets exclusion regardless. The settings description for the
vehicle toggle is the only one that may state exclusion.

A faction refusal now applies at most seven modifiers per target rather than a number that varied
with an unrelated setting. `SameClassSet` is consequently always true and `m_appliedClasses` no
longer drives rebuilds; it is retained as the flag recording that a batch has been populated.

The generalisable finding is that 0011 was reasoned correctly from a proven premise and was still
wrong. 0006 established that the class axis cannot exclude a target, and the inference that
exclusion must therefore travel the faction axis was valid but unverified for vehicles. The step
that was skipped is the cheap one: confirming that the destination mechanism works on the target
type being moved. A mechanism proven on puppets was assumed to hold for every entity the smart gun
can track.
