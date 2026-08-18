# 0015. The mod ships an archive

## Status

Accepted. Reverses the shipping constraint adopted in
[0004](0004-no-localization-archive.md); leaves the display-name decision in
[0008](0008-display-names-via-codeware.md) intact.

## Context

[0004](0004-no-localization-archive.md) decided to ship no `.archive`. Its reasoning was about
cost rather than principle: backing a custom localization key requires a cooked `JsonResource`
inside an archive, producing one requires WolvenKit and a pack step, and adding a build dependency
only some contributors can run was judged too expensive for the handful of strings it would
deliver. [0008](0008-display-names-via-codeware.md) later superseded 0004 on the display-name
question by registering names through Codeware at runtime, which needs no archive at all.

The icon is a different problem with the same shape. `iconPath` on an item record names a
`UIIcon` record, which resolves to an `inkatlas` part. An atlas is a cooked resource. Unlike a
display name there is no runtime registration path for one, so the choice is between a vanilla
icon that depicts something else and shipping a resource.

The cost that 0004 weighed has also fallen. WolvenKit is now installed and the atlas is built, so
the pack step exists whether or not it is used again.

## Decision

Ship `kstp.archive`, containing one atlas and one texture for the coprocessor icon.

`UIIcon.KSTPCoprocessor` points at `base\kstp\icons\kstp_coprocessor.inkatlas`, part name
`kstp_coprocessor`. The item records carry `iconPath: KSTPCoprocessor` as a bare suffix, which the
resolver prefixes with `UIIcon.`.

ArchiveXL becomes a real dependency rather than a nominal one. It was previously listed as
optional on the grounds that nothing loaded through it, and that statement is no longer true.

The WolvenKit project stays in the repository under `src/archive/source/`, so the atlas can be
rebuilt rather than only redistributed. Build outputs that WolvenKit regenerates are not committed.
The full-resolution master the shipped PNG was reduced from is kept alongside it, outside the
project and outside any build path, so a different icon size can be exported without redrawing.

## Consequences

Contributors who change the icon need WolvenKit. Everyone else does not: the built archive is
committed, so a clone deploys and runs without it. This is the compromise 0004 could not reach,
and it only became available once the artefact existed.

Without ArchiveXL the atlas does not load. The item still resolves and the mod still functions;
the icon falls back. This is a degraded appearance rather than a failure, consistent with how every
other soft dependency degrades (ADR 0010), but it is now a case worth testing rather than a case
that cannot arise.

The part name is the silent failure. A wrong `atlasPartName` compiles, loads, and renders nothing
diagnosable: TweakDB reports no error and the icon simply falls through to the native resolver.
The name is verified against the built atlas rather than assumed.

Nothing here reopens [0008](0008-display-names-via-codeware.md). Display names continue to be
registered through Codeware at runtime. Moving them into this archive as a cooked `JsonResource` is
now possible, and would trade a soft dependency on Codeware for a soft dependency on ArchiveXL,
which is not obviously a gain and is not proposed.
