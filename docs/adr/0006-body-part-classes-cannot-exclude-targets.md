# 0006. Body-part classes cannot exclude targets

## Status

Accepted; scope narrowed by [0013](0013-each-axis-enforces-its-own-question.md). Vehicle is the
one class the mask does exclude, hard-denied under either lock policy. The finding below holds
for the other six.

## Context

The body-part axis writes `SmartGunTrack*Components` stats on the held weapon's item-data stats
object. Disabling a class removes it from the set of slots the gun will lock onto.

An appealing shortcut follows from that: disable every class a given kind of target possesses, and
that kind of target becomes unlockable. Disable Head, Chest, Leg and WeakSpot and humans should
drop out, leaving Mechanical and Vehicle for an anti-machine protocol.

The native handler does not behave that way. When no enabled class matches a candidate, it falls
back to a raw head slot rather than discarding the candidate (`weapon.script:1526`). The lock
lands on a default bone and the target is engaged normally.

The two axes are therefore answering different questions, and only one of them can answer
"may this target be locked at all".

## Decision

Treat the body-part classes as controlling WHERE a lock lands. Treat the faction and threat axis
as controlling WHETHER a target may be locked at all.

No protocol relies on body-part configuration to exclude a category of target.

## Consequences

`ANTI-MACHINE` cannot exclude humans. It enables Mechanical and Vehicle and disables the rest, and
against a human that leaves nothing enabled, so the fallback engages and the lock currently lands
on the chest. The preset does what its name suggests against drones and vehicles and does not
refuse humans.

The correct fix is a threat-class filter on `KSTPProtocol`, so `ANTI-MACHINE` denies the Civilian,
Police, Ganger and Netrunner threat classes on the faction axis while its body-part configuration
handles only slot preference. That filter is not implemented.

Protocols that narrow the body-part set are still doing useful work: `PRECISION`, `CRIPPLE` and
`SURGICAL` change which part of a permitted target the gun spends its lock time on, which is what
the axis is for.

Documentation and settings descriptions must not describe a body-part preset as excluding a kind
of target, because no such preset does.
