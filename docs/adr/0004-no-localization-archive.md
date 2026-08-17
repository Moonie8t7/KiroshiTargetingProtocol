# 0004. No localization archive

## Status

Superseded by [0008](0008-display-names-via-codeware.md). The fallback this record depended on
does not exist for item names, and the failure it anticipated is the one that occurred.

## Context

TweakXL display fields such as `displayName` and `localizedDescription` are LocKey wrappers. They
take the name of a localization key, never display text. Every localized field across the
reference corpus passes a key:

```yaml
displayName: LocKey(79138)                    # vanilla numeric key
displayName: LocKey#Mod-Edg-Pre-Psychosis     # custom key
displayName: l"Mod-Edg-Ripper-Med"            # the same custom key, l"" form
```

Backing a custom key requires a cooked `JsonResource` inside an `.archive`, wired up by an
ArchiveXL `.xl` manifest. Producing that archive requires WolvenKit and a pack step. This project
has neither, and adding a build dependency that only some contributors can run costs more than the
handful of strings it would deliver.

Two options remain: reuse a vanilla LocKey, which supplies the wrong words, or pass a custom key
and rely on the unresolved-key fallback, which renders the key verbatim.

## Decision

Ship no `.archive`. Pass custom keys whose text is the wording wanted on screen, and accept that
the text appears because the key failed to resolve:

```yaml
displayName: l"Kiroshi IFF Targeting Coprocessor"
```

Vanilla LocKeys remain acceptable wherever the base game already ships the right words.

## Consequences

Item and ability names on TweakXL records render as their own key strings. The wording is chosen so
this reads as intended English rather than as a broken key, but it is a key, and nothing in the
resolver treats it as text.

Localization into other languages is not possible for these strings. A player running the game in
another language sees the English key text.

The fallback behavior is what makes this work, and it is not contractual. If the resolver ever
returns an empty string instead of the key, the affected records become nameless. No mechanic
depends on any of these strings, so the failure is cosmetic. The fix, if it comes to that, is a
real `.archive` with an ArchiveXL localization entry.

Mod Settings labels are unaffected. That framework renders the literal string in the
`@runtimeProperty("ModSettings.displayName", ...)` annotation, so `UI/Settings.reds` and
`Core/Gate.reds` carry their English text directly and no key is involved.
