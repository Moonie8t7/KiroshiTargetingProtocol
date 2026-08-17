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
- US English, matching the game and the wider mod ecosystem: `behavior`, `color`, `initialize`.
- Two-space indentation in redscript, matching the decompiled sources.
- Keep lines under roughly 95 characters.

## Naming

Everything with global reach carries the `KSTP` prefix: classes as `KSTPFoo`, free functions as
`KSTP_Foo`. A redscript mod shares one namespace with every other mod the player has installed,
and a collision is their problem rather than ours.

Check for an existing method of the same name before adding one to a class. Two methods sharing a
name on one class compile without complaint and then fail at registration, before the main menu,
with nothing in the log.

## Logging

`KSTPLog.Info` is for events a player might reasonably see: startup, teardown, a protocol change.
Everything else is `KSTPLog.Debug`, which is off unless verbose logging is switched on in the
settings.

Nothing logs per frame or per entity at Info. Build interpolated strings only after checking
`KSTPLog.DebugEnabled()`, so the string is never assembled when tracing is off.

Messages are lowercase, factual, and carry the numbers a bug report needs.

## Documentation

Tables beat prose wherever more than about three parallel facts are involved. Code fences carry a
language tag. A document recording a decision states the decision and the evidence for it; the
route taken to reach it belongs in the commit history.
