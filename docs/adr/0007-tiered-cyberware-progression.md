# 0007. Tiered cyberware progression

## Status

Partly superseded by [0009](0009-settings-are-the-contract.md). The faction and threat axis is
no longer gated at tier 3: it is available at any tier, and `KSTP_FactionAxisMinTier()` is
deleted. Statements below about that gate record the decision as taken, not current behavior.
The eleven-tier ladder, the per-tier class coverage and the flat capacity cost stand.

## Context

One cyberware record at a single quality cannot occupy the place the game gives cyberware. Every
vanilla implant runs an eleven-step quality ladder, Common through Legendary++, and the systems
around cyberware assume that shape. Ripperdoc stock is filtered by player level, so a fixed-quality
record either sits in the list from the first clinic visit or never appears at it. The ripperdoc
upgrade panel walks a per-record chain, so a record with no chain cannot be upgraded. The result
reads as an unfinished item next to the eleven-tier roster around it.

The implant's effect is a set of unlocks rather than a scaling number. It switches on the smart-gun
component classes vanilla ignores and puts a protocol layer in front of the smart link. There is no
percentage to raise per tier, which is what the vanilla ladder normally scales.

Two things could scale instead: which component classes the implant unlocks, and whether the faction
and threat axis is enforced at all. Both are already discrete, and both are already legible to a
player through the IFF overlay.

## Decision

Ship eleven records, one per vanilla quality grade, named `Items.KSTPKiroshiIFFCoprocessor<Grade>`.

Scale which component classes the implant unlocks:

| Tier | Grades | Unlocks |
|---|---|---|
| 1 | Common, Common+ | Head |
| 2 | Uncommon, Uncommon+ | Weak spot |
| 3 | Rare, Rare+ | Breach, and the faction and threat axis |
| 4 | Epic, Epic+ | Vehicle |
| 5 | Legendary, Legendary+, Legendary++ | All classes, and permitted classes lock faster |

Gate the faction and threat axis at tier 3, the point where vanilla introduces attribute attunement
on a frontal cortex implant, so the ladder's own midpoint carries the mod's one behavioral unlock.
`KSTP_FactionAxisMinTier()` in `Core/Policy.reds` is the single definition of that threshold.

Hold cyberware capacity flat at 6 across all eleven records, charged with
`variants: [Variants.Humanity6Cost]`. That matches the vanilla convention: Bioconductor charges 16
at Common and 16 at Legendary++. Price is what scales with quality, through the standard
`Price.BaseCyberwarePrice` chain.

## Consequences

**The faction axis is unavailable below tier 3.** That is the gate, and the mod does not pretend
otherwise: tiers 1 and 2 classify every tracked target and label it `PERMIT` or `REFUSE` in the
overlay while suppressing none of them. The feature is visible before it is owned, which is what
makes the upgrade worth buying. It also means a report of "faction filtering does nothing" has a
tier question in front of it before anything else is investigated.

**The eleven record names are pinned in two places.** `Core/Policy.reds` matches each literal in
`KSTP_CyberwareTierOf()`, and `src/r6/tweaks/KSTP/cyberware.yaml` authors it. A `TweakDBID` literal
is a compile-time hash that does not require the record to exist, so a mismatch produces no
diagnostic from redscript, none from TweakXL, and none in the log. The symptom is a tier that
returns 0: the implant equips, costs capacity, and the mod is inert for anyone wearing that grade.
Renaming a record means editing both files in the same change.

**A tier check is script, a class unlock is data.** The per-tier component classes come from the
stat group each record points at, so adding or moving an unlock is a yaml edit with no script
change. The faction gate is behavior rather than a stat, so it is the one thing script reads the
tier for. Splitting it this way keeps `KSTP_CyberwareTierOf()` as the only place in script that
knows a record name.

**Flat capacity means the ladder is not a cost decision.** Upgrading never charges more headroom, so
a player who fits the implant at tier 1 keeps it fitted at tier 5++ regardless of what else was
installed in between. The trade is eddies only.

**The mod is worth buying early and worth upgrading.** A single Epic record is neither: it is absent
from ripperdoc stock for most of a playthrough, and terminal the moment it appears.

**Eleven records cost eleven times the authoring surface.** The yaml uses `$instances` templating to
keep that to one block, so a change to the shared shape is written once. The eleven names, the
per-tier stat groups and the upgrade chain still have to be correct individually.
