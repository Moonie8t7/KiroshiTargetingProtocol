# 0008. Display names registered through Codeware

## Status

Accepted. Supersedes [0004](0004-no-localization-archive.md).

## Context

[0004](0004-no-localization-archive.md) passed display text as the localization key itself and
relied on the resolver echoing an unresolved key back. It flagged that behavior as
non-contractual and named the failure it would cause: nameless records.

That failure is what shipped. On build 2.31 the eleven coprocessor tiers render with an empty
name in the ripperdoc and inventory panels. The tier, capacity, price and description all
resolve; only the name is blank.

The cause is that two different natives back these fields, and only one of them tolerates an
unregistered key:

| Field | Native | Behavior on a miss |
|---|---|---|
| Item record name | `GetLocalizedItemNameByCName` (orphans.script:20082) | empty string |
| Package UIData strings | `GetLocalizedText` (orphans.script:19622) | returns its input |

The first takes a `CName` its own signature calls `hashKey`: it hashes the argument and looks the
result up in the on-screen table. Nothing in that path can return the key's text. The second takes
a `String` and echoes it, which is why the gameplay logic package description rendered correctly
while the item name beside it did not. ADR 0004 generalized from one of these to both.

Confirming the fields themselves were sound: TweakXL logged 1226 property errors from other mods
in the same run and none for KSTP, so every field was accepted and set. The values simply do not
resolve.

Three ways to register a real key were available:

- An `.archive` carrying a cooked JSON, the route ADR 0004 named. Every one of the 2002 onscreen
  entries across the installed corpus resolves from inside an archive; not one resolves from a
  loose file, so ArchiveXL cannot be pointed at a plain JSON on disk. WolvenKit is present here
  but ships no CLI, so this means a manual GUI step no automated build can reproduce.
- A vanilla LocKey, which supplies the wrong words.
- Codeware's localization system, which registers on-screen entries from script.

Codeware builds `localizationPersistenceOnScreenEntry` values with `primaryKey` left at zero and
`secondaryKey` set to the key string (Codeware.Localization.reds:366-370). That is the same shape
an archive JSON writes, and it resolves against the same LocKey token.

## Decision

Register display strings from script through Codeware, in `UI/Localization.reds`, and pass real
LocKey tokens from the item record:

```yaml
displayName: LocKey#kstp_coprocessor_name
```

The declaration sits behind `@if(ModuleExists("Codeware.Localization"))`, matching the guards
already used in `Enforcement/Faction.reds` and `Input/Hotkeys.reds`.

Gameplay logic package UIData fields stay plain scalars. They resolve through the native that
echoes its input, so they keep working with no dependency at all. This asymmetry is deliberate and
is noted at both sites.

Ship no `.archive`. That half of ADR 0004 stands.

## Consequences

Codeware becomes a soft dependency for presentation. With it, names render correctly. Without it,
the guarded file compiles out and the item names render blank, exactly as they do today. Nothing
else regresses, because no gameplay path reads these strings. Codeware is already required by
`Enforcement/Faction.reds` for its spawn observer, so this widens an existing dependency rather
than adding one.

The keys are duplicated between `src/r6/tweaks/KSTP/cyberware.yaml` and `UI/Localization.reds`.
Renaming one without the other restores the blank name and reports nothing on either side. Both
sites carry a comment saying so.

Localization into other languages is now possible, which it was not under ADR 0004: a package per
language is a script change with no pack step. The shipped strings remain English only, and every
locale is served the English package rather than an empty card.

The verification that mattered here was negative evidence being unavailable. A blank name produces
no log line from TweakXL, redscript or the game. What identified it was reading the two natives'
signatures and noticing that one parameter is named `hashKey`.
