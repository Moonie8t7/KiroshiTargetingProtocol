# 0016. The overlay requires the implant

## Status

Accepted.

## Context

The IFF overlay drew whenever a smart weapon was up, whether or not the coprocessor was fitted.
Without the implant every refusal rendered as `REFUSE*`, an advisory verdict meaning "this target
would be refused, but nothing is enforcing it". The reasoning was that a player below the enforcing
tier still gets useful information, and that showing it costs nothing.

Field testing on 18 August 2026 showed what it costs. With the coprocessor removed and the mod
verifiably inert, the labels still appeared:

```
bodypart     0     no weapon-stat writes
sweep:       0     no ledger pass
seed:        0     no radius query
lock list    0     no per-frame decisions
suppress     0     nothing applied to any NPC
```

Enforcement was doing nothing whatsoever, and the display said otherwise. Across three test rounds
the labels were read as evidence the mod was still enforcing, twice sending the investigation after
defects that did not exist. A test criterion written against them had to be retracted.

The deeper problem is that the overlay is the only part of the mod a player can see. When the one
visible surface runs independently of the item that powers it, there is no way to tell a working
install from a broken one by looking.

## Decision

The overlay requires the coprocessor. `ShouldDraw()` returns false when
`KSTPPolicySystem.FactionAxisAvailable()` is false, which is `m_cyberwareTier > 0`: the implant
fitted, at any tier.

The check runs per tick rather than being cached at attach, so removing the implant clears the
labels on the next frame instead of at the next weapon draw.

The tier ladder is unaffected. Any grade draws the overlay; the tier continues to govern which
target classes a protocol may unlock, as ADR 0007 sets out.

## Consequences

The labels become a direct indicator of install health. Present means the implant is fitted and the
overlay path is alive; absent means one of those is not true. That is worth more than the advisory
information it replaces, because it is the only feedback the mod offers without reading a log.

Advisory refusals survive but narrow. `RefusedAdvisory` was reachable in two ways: no implant, and
the E-STAT experiment gate switched off. The first is now impossible, leaving the gate, where the
verdict is real and deliberately unenforced. That is a development state rather than a player one,
so in practice `REFUSE*` now means "a gate is off" and nothing else.

A player who removes the coprocessor loses the readout as well as the enforcement. This is the
intended reading of the item: the overlay is the coprocessor's output, not a separate feature that
happens to sit near it.

Absent Mod Settings the overlay ships on ALWAYS, and this gate sits above that setting. A player
with no implant sees nothing regardless of visibility mode, which is the correct off state rather
than a regression in the no-framework path (ADR 0010).
