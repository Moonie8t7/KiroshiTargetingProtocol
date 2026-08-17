# 0011. The two controls 0009 missed

## Status

Accepted. Partly supersedes [0006](0006-body-part-classes-cannot-exclude-targets.md) and corrects
[0009](0009-settings-are-the-contract.md).

The vehicle decision below is superseded by
[0013](0013-each-axis-enforces-its-own-question.md): routing vehicle refusal onto the faction axis
was measured not to work, and exclusion is enforced by the class mask instead. The overlay
visibility decision stands.

## Context

[0009](0009-settings-are-the-contract.md) states the rule: if a control is shown, it applies. It
was written after two controls were found that could be set and have no effect. Both of the
controls below survived that pass, and both were found the same way the first two were, by a
player setting something and watching the mod ignore it.

**Lock VEHICLE did not refuse vehicles.** [0006](0006-body-part-classes-cannot-exclude-targets.md)
had already established why, and in terms that leave no room: the body-part classes write
`SmartGunTrack*Components` stats, and when no enabled class matches a candidate the native handler
falls back to a raw head slot rather than discarding it (`weapon.script:1526`). The class axis
decides where a lock lands. It cannot decide whether one happens.

`classVehicle` was nevertheless given this description in the same change that wrote 0009:

> Off by default: a smart gun that acquires traffic while you are aiming past it is the single
> most common way to start a fight you did not want.

and 0009's own consequences claimed a fresh install "does not lock onto police, medics or passing
traffic." The traffic half of that rested entirely on a toggle that 0006 had already ruled
incapable of it. Six of the seven class toggles steer; the seventh was asked to refuse, and
quietly did not.

**The overlay key did nothing.** `KSTPOverlayConfig` carried three independent booleans:
`Enabled`, `OnlyWhileADS`, `OnlyWhileHeld`. `ShouldDraw()` consulted the hold flag only inside the
second and third:

```
if OnlyWhileHeld && !held                          return false
if OnlyWhileADS && !held && !IsAimingDownSights()  return false
```

With both "only while" options off (the shipped default), the overlay key was written by the
input listener and read by nothing. Pressing it produced no change of any kind, and nothing
distinguished that from a broken keybind, an unloaded input XML, or a missing framework. The
explanation lived in a different settings group, on the control that governs hold-versus-toggle.

Off, aiming and key-held are mutually exclusive answers to one question. As three booleans they
had eight states, of which four were meaningful.

## Decision

**Vehicle refusal travels the faction axis.** `KSTPClassification` gains `isVehicle`, and
`KSTPClassifier.Permits()` refuses a vehicle whose target class is unticked. That places the
decision on the axis that can deny a target rather than the one that cannot, which is the fix
[0006](0006-body-part-classes-cannot-exclude-targets.md) named and left unbuilt. The test sits
above the `factionFilterEnabled` early return, because it is a class decision and must hold with
faction filtering switched off, and `Enforcement/Faction.reds` no longer bails out of its sweep
when only the vehicle axis is asking for work.

**Overlay visibility is one control.** The three booleans are replaced by
`KSTPOverlayVisibility`: `ALWAYS`, `ONLY WHILE AIMING`, `ONLY WITH THE OVERLAY KEY`, `NEVER`. The
key's role is now stated by the control that governs it, and no setting leaves it dead.

## Consequences

`Suppress()` needed a vehicle branch, and the reason is worth recording because the obvious
implementation is silently wrong. `m_appliedClasses` is the set of classes a *permitted* target
keeps, which is what a faction refusal inflates: every avenue the gun would otherwise use against
that NPC. A vehicle refusal is the opposite shape. Its class is by definition unticked, so it is
absent from that set, and a loop reading it would have written no vehicle modifier at all. The
refusal would have compiled, deployed, and done nothing: the same defect being fixed, one layer
down. Vehicles now inflate `SmartGunTimeToLockVehicleComponentMultiplier` alone, since a vehicle
carries exactly one lockable class and the other six would be modifiers the handler never reads.

Vehicle refusal inherits the faction axis's gates: `KSTPGate.FactionAxisEnabled()` and an
installed coprocessor. Turning the experiment gate off now also stops vehicles being refused. That
is a real coupling and the price of reusing the one mechanism that is known to work on 2.31
([0003](0003-faction-via-lock-time-inflation.md)) rather than adding a second.

The three removed overlay fields stay in any existing `user.ini`. Mod Settings maps by field name
and ignores keys with no matching field, so they are inert, and the new control starts at its
default rather than at a migrated value. A player who had configured hold-to-show has to set it
again, once.

Both defects had the same signature as the two in 0009 and neither was caught by writing 0009.
The rule was stated and then applied only to the controls already known to be broken. What would
have caught these is not a stricter rule but a cheaper question asked of every shipped control:
name the code path that makes this setting change what the game does. `classVehicle` had no such
path and 0006 already said so in writing.
