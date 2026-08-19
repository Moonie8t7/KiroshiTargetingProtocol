# 0017. Inherit from vanilla records rather than reconstructing them

## Status

Accepted.

## Context

The coprocessor item was authored as a complete `gamedataItem_Record`, seventy-one fields
written out by hand. The stated reason, recorded in `cyberware.yaml` itself, was that no
frontal-cortex item ID could be confirmed against the 2.31 script dump, and that a `$base`
pointing at a record which does not exist fails silently rather than erroring.

Both halves were true when written. Neither survived contact with evidence.

Three frontal-cortex IDs can be read directly off an equipped loadout at runtime:
`AdvancedBioConductors`, `AdvancedExDisk` and `AdvancedSubdermalCoProcessor`. The last carries
all eleven quality steps and is a coprocessor, making it the closest possible parent.
Separately, BlackChrome, a cyberware mod already installed in the development environment, has
shipped `$base`-cloned implants throughout: `$base: Items.AdvancedBloodPump$(tier)` and a
dozen more.

The hand-authored record then failed in a way that was very hard to diagnose. A ripperdoc rolls
a random per-tier stat bonus onto every implant it stocks, and ours received none: its card
showed a description and an attunement where a vanilla implant of the same tier showed three
rolled stats. The cause was one of the fifty-nine surplus overrides suppressing the roll.
Which one was never identified, and that is the point. A record which declares almost every
field the game has offers no way to find the field that matters by adding more.

Four separate attempts to fix it by adding or changing individual fields failed:
`statModifierGroups` (empty on every vanilla record too), `$base` alone (necessary but not
sufficient while the overrides remained), the structural `statModifiers` pair, and the vendor
gating records, which were never the cause at all.

Stripping the record from seventy-one fields to sixteen fixed it in one change.

## Decision

Modded records `$base` from the closest vanilla equivalent and declare only what must differ.

For the coprocessor that is `Items.AdvancedSubdermalCoProcessor$(quality)`, and the sixteen
fields are: the two template inputs, the display strings, `cyberwareType`, `quality`,
`nextUpgradeItem`, the icon pair, `statModifiers`, `variants`, the two price chains, `tags` and
`OnEquip`.

A field written out to what looks like its default is not neutral. It is an assertion that
beats inheritance, and it silently opts the record out of whatever the parent would have
supplied. If a value does not need to differ, it does not get written.

## Consequences

The record is smaller, the file lost roughly four hundred lines, and behaviour the base game
provides now arrives without anyone having to know it exists. That last point is the real
gain: the roll was suppressed by a field nobody knew was load-bearing, and inheritance means
the next such field is inherited correctly whether or not we ever learn its name.

The parent's values apply wherever this record is silent, so a vanilla patch that changes the
subdermal coprocessor changes this implant too. That is usually correct and occasionally not,
and it is the trade inheritance makes.

`statModifiers` stays declared and does not inherit. The parent's third modifier is a
crit-chance bonus, and this implant grants targeting behaviour rather than a stat.

## A note on this project's own comments

Four times in one session a comment in this repository asserted something that was true when
written and false by the time it was read: that the mod ships no `.archive`, that only one
ripperdoc vendor ID is confirmable, that no frontal-cortex base record can be confirmed, and
that `statModifiers` is empty on the base record. Each was quoted as justification for leaving
something alone. Each was wrong, and each was cheap to check.

A comment recording why a decision was made is evidence about the past, not about the present.
Where one asserts that something is impossible or absent, the claim is checked before it is
relied on, and the reference corpus in the development environment is the fastest place to
check it. Every one of those four questions was answered from an installed mod in minutes,
after hours spent reasoning from the comments instead.
