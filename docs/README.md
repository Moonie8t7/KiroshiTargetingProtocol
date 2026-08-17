# KSTP documentation

Where each document sits and what it is for. The mod itself is described in the
[root README](../README.md); everything here is for someone changing it.

## Start here

| Document | Covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | The layout, which layer may do what, and how a settings change reaches the game |
| [CONTRIBUTING.md](CONTRIBUTING.md) | The build and test loop, the tools, and the rules that are not negotiable |
| [STYLE.md](STYLE.md) | Conventions for source and documentation, including where reasoning belongs |
| [COMPATIBILITY.md](COMPATIBILITY.md) | Required frameworks, what breaks when one is missing, contending mods, and save impact |

## Decisions

[adr/](adr/README.md) holds one record per decision that shaped the mod: the constraint that
forced it and what was given up by taking it. Records are immutable once accepted; a decision that
changes gets a new record superseding the old one.

Read a record before changing the behaviour it governs. Several exist because the obvious approach
was tried and measured not to work, and the code alone does not say so.

## Reference

| Document | Covers |
|---|---|
| [research/smart-gun-internals.md](research/smart-gun-internals.md) | How smart-gun targeting is wired on build 2.31, every claim citing `file:line` into the decompiled dump |
| [research/experiments.md](research/experiments.md) | Which enforcement mechanisms were tested in game and what each was measured to do |

`smart-gun-internals.md` describes the engine. `experiments.md` describes what this mod can and
cannot make the engine do, and is the document to check before assuming a mechanism works on a
target type it has not been tried against.

## Evidence

[evidence/](evidence/) holds dated raw captures from the CET diagnostic lab, kept as recorded.
They are the primary source behind the experiment results and are not edited after the fact. A
capture reflects the build and configuration of its date, not current behaviour.

## Conventions

Anything asserted about the base game carries a `file.script:line` reference into the decompiled
2.31 dump. Claims that could not be verified that way are marked `UNVERIFIED` at the point they
affect, with a note on what would confirm them and what breaks if they are wrong.
