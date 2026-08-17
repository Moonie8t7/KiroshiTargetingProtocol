# 0009. Settings are the contract

## Status

Accepted.

## Context

Two controls in the settings menu could be set and have no effect, with nothing written to
any log to say why. Both were found the same way: a player turned something off, watched the
mod ignore it, and reported a bug that was not a bug.

**The class-mask override.** The seven target-class toggles were gated behind an eighth
switch, `overrideClassMask`, defaulting off. With it off the toggles were read but discarded
and the selected protocol's own mask was used instead. Turning VEHICLE off did nothing.

**The faction tier gate.** `KSTP_FactionAxisMinTier()` returned 3, so faction filtering did
nothing until a Rare or better coprocessor was installed. The twenty-odd faction toggles
stayed visible and settable at tier 1, and the sweep logged its intent honestly enough:

```
sweep: 8 live NPC(s), 0 streamed out, suppression 5 -> statMod=0 ignore=5
```

Five NPCs identified for suppression, zero modifiers applied.

Each was defensible alone. The override existed because Mod Settings is a static menu and
cannot show a different mask per protocol, so the toggles had to be an override layer rather
than an editor. The tier gate existed to give the ladder a headline feature at tier 3.

Together they made the shipped defaults untrue. A fresh install could not express "do not
lock police" at all: the faction axis was inert below tier 3, and the class toggles were
inert until a second switch was found.

## Decision

The settings menu states what the mod does. If a control is shown, it applies.

- `overrideClassMask` is deleted. The seven class toggles are the class mask, always.
  Selecting a protocol rewrites them, so the menu shows what is actually in force.
- The faction axis is available at every tier. `FactionAxisAvailable()` now tests only that
  a coprocessor of some grade is installed.
- Defaults are a working baseline rather than a neutral one: `classVehicle` off,
  `factionFilterEnabled` on, and NCPD, Trauma Team, Aldecaldos and Afterlife mercs unticked.
  A fresh install does not lock onto police, medics or passing traffic.
- Every debug-only control is grouped under a `Debug - ` prefix ordered above 900, so what a
  player tunes sorts above what a bug report needs: the IFF overlay, its layout, the
  experiment gates, verbose logging and the multi-target ADS switch.

## Consequences

The tier ladder now buys exactly two things: which target classes the coprocessor can reach,
and the Intelligence attunement at tier 3. It no longer buys the right to choose who to
engage. That is a flatter ladder and a smaller reason to upgrade, and it is the price of the
defaults being honest at tier 1.

Presets are no longer a competing layer. They seed the toggles; the toggles decide.

A stale `overrideClassMask` key remains in any existing `user.ini`. Mod Settings maps by
field name and ignores keys with no matching field, so it is inert.

`allowCivilians` is deliberately left at its current default rather than being flipped to
match the good-citizen baseline. Setting it false previously suppressed 101 of 101 NPCs,
because the classifier attributes a civilian affiliation far more widely than the name
suggests. That is a classifier problem, and flipping the default without fixing it would
reintroduce a worse bug than the one being fixed.

The failure mode this record exists to prevent is not a crash. It is a control that lies.
Both bugs cost a play session each to find, and neither produced a single line of evidence
until someone went looking at the settings file by hand.
