# House style

Conventions for source and documentation in this repository.

## Comments

Comment the non-obvious. A comment that restates its own code is noise, and noise trains the
reader to skip comments that matter.

A comment earns its place when it records something the code cannot say for itself:

- an ordering requirement, or a reason a call has to happen where it does
- a failure mode, especially a silent one
- why the obvious simpler approach was not taken
- a constraint imposed by the game rather than by this mod

File headers state what the module owns and what it must not do. Function comments are warranted
where the function carries a constraint, not as a matter of routine.

Reasoning lives in `docs/adr/`, not in the source. A comment that argues a case, recounts what was
tried first, or narrates a defect belongs in a record; the source cites it by number. Inside a
function body the default is no comment at all: write one only where a reader changing that line
would otherwise break an invariant, and then state the invariant and stop.

## Citing game internals

Anything asserted about the base game carries a `file.script:line` reference into the decompiled
scripts, so the claim can be checked rather than trusted. Statements that could not be verified
that way are marked `UNVERIFIED` at the exact line they affect, with a note on what would confirm
them and what breaks if they are wrong.

This matters more here than in most projects. A TweakDBID literal that names no record still
compiles, and the game still loads. Wrong assumptions do not announce themselves.

## Formatting

- ASCII only in source. Use `->` rather than an arrow character, and straight quotes.
- British English in comments and documentation: `behaviour`, `colour`, `prioritised`.
- US English wherever the player reads the text, matching the game: the Mod Settings labels and
  descriptions, and the item strings in `UI/Localization.reds`. Identifiers that mirror a game or
  framework API keep that API's spelling, such as `HDRColor` and `ModLocalizationProvider`.
- Two-space indentation in redscript, matching the decompiled sources.
- Wrap comment prose at about 100 characters. Declarations and the display strings inside
  `@runtimeProperty` annotations run past that; an annotation argument is a single literal and is
  not broken across lines.

## Naming

Everything with global reach carries the `KSTP` prefix: classes as `KSTPFoo`, free functions as
`KSTP_Foo`. A redscript mod shares one namespace with every other mod the player has installed,
and a collision is their problem rather than ours.

Check for an existing method of the same name before adding one to a class. Two methods sharing a
name on one class compile without complaint and then fail at registration, before the main menu,
with nothing in the log.

Two bodies under complementary `@if(ModuleExists(...))` guards are not a duplicate: the compiler
resolves the guard and keeps exactly one, which is how every optional dependency is probed
(ADR 0010).

## Logging

`KSTPLog.Info` is for events a player might reasonably see: startup, teardown, a protocol change.
`KSTPLog.Warn` is for a degraded but survivable state, such as a missing framework or an optional
lookup returning null, and `KSTPLog.Error` for a contract violation, where a game API returned
what the dump says it cannot. Everything else is `KSTPLog.Debug`, which emits only when verbose
logging is switched on in the Debug group of Mod Settings, and is off by default (ADR 0010).

Nothing logs per frame or per entity at Info. Build interpolated strings only after checking
`KSTPLog.DebugEnabled()`, so the string is never assembled when tracing is off.

Messages are factual and carry the numbers a bug report needs. The `[KSTP]` prefix is added by the
sink, so callers pass an undecorated string.

## Documentation

Tables beat prose wherever more than about three parallel facts are involved. Code fences carry a
language tag; excerpts of log output or of the decompiled dump are fenced bare. A document
recording a decision states the decision and the evidence for it; the route taken to reach it
belongs in the commit history. A record is immutable once accepted: a decision that changes gets a
new record superseding the old one rather than an edit, and the index in `docs/adr/README.md`
carries the status.
