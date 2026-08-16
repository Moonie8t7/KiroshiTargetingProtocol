# 0005. Civilians allowed by default

## Status

Accepted

## Context

Faction denial applies a stat modifier to each denied NPC (ADR 0003), so its cost scales with the
number of NPCs the active protocol refuses.

Civilians and crowd NPCs are the overwhelming majority of the population in any street scene.
With civilians denied, enabling faction filtering suppressed effectively every NPC in the
district: a sweep of a busy street reached 101 of 101 NPCs, each carrying its own modifiers and
its own entry in the restore ledger. The gangers the protocol was meant to permit were a rounding
error in that total.

The player-facing result was a feature that appeared to do nothing useful while doing an enormous
amount of work, because the interesting targets were unaffected and the pedestrians the player was
never going to shoot carried the entire cost.

Refusing civilians is still a legitimate thing to want. A player who wants the smart link to
physically refuse to lock a bystander should be able to have it.

## Decision

`allowCivilians` defaults to `true` on every shipped protocol. The flag covers the `Civilian`
affiliation and anything the classifier flags as a civilian or crowd NPC, whichever faction record
the NPC happens to carry.

## Consequences

Refusing civilians is opt-in. A player who wants it turns off "Allow civilians" in Mod Settings and
accepts the cost.

The cost of the faction axis scales with the factions a protocol denies rather than with the
population of the district. A protocol refusing only a gang touches the members of that gang.

The IFF overlay still labels civilians as `CIVILIAN` and still shows the protocol verdict, so the
classification is visible whether or not it is enforced.

The default does not protect civilians from being shot. It means the smart link does not refuse to
lock them; aim discipline remains the player's.
