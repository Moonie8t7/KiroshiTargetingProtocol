# Architecture decision records

An ADR here records one decision that shaped the mod, the constraint that forced it, and what the
project gave up by taking it. Each record is written so a reader who arrives at the same fork
years later can see why the obvious road was not taken and what evidence would justify revisiting
it. Records are immutable once accepted: a decision that changes gets a new record that supersedes
the old one rather than an edit. Supporting evidence with `file:line` citations into the
decompiled 2.31 scripts lives in [../research/smart-gun-internals.md](../research/smart-gun-internals.md); the interfaces every module
codes against live in [../ARCHITECTURE.md](../ARCHITECTURE.md).

| # | Decision | Status |
|---|---|---|
| [0001](0001-no-native-plugin.md) | No native plugin | Accepted |
| [0002](0002-no-replacemethod.md) | No `@replaceMethod` | Accepted |
| [0003](0003-faction-via-lock-time-inflation.md) | Faction denial by lock-time inflation | Accepted; scope narrowed by [0013](0013-each-axis-enforces-its-own-question.md) |
| [0004](0004-no-localization-archive.md) | No localization archive | Superseded by [0008](0008-display-names-via-codeware.md); shipping constraint reversed by [0015](0015-the-mod-ships-an-archive.md) |
| [0005](0005-civilians-allowed-by-default.md) | Civilians allowed by default | Accepted |
| [0006](0006-body-part-classes-cannot-exclude-targets.md) | Body-part classes cannot exclude targets | Accepted; scope narrowed by [0013](0013-each-axis-enforces-its-own-question.md) |
| [0007](0007-tiered-cyberware-progression.md) | Tiered cyberware progression | Partly superseded by [0009](0009-settings-are-the-contract.md) |
| [0008](0008-display-names-via-codeware.md) | Display names registered through Codeware | Accepted; its restatement of the no-archive constraint reversed by [0015](0015-the-mod-ships-an-archive.md) |
| [0009](0009-settings-are-the-contract.md) | Settings are the contract | Accepted; corrected by [0011](0011-vehicle-refusal-and-overlay-visibility.md) |
| [0010](0010-mod-settings-is-a-soft-dependency.md) | Mod Settings is a soft dependency | Accepted |
| [0011](0011-vehicle-refusal-and-overlay-visibility.md) | The two controls 0009 missed | Accepted; vehicle half superseded by [0013](0013-each-axis-enforces-its-own-question.md) |
| [0012](0012-blackboard-delivery-via-the-host-controller.md) | Blackboard delivery through the host controller | Accepted |
| [0013](0013-each-axis-enforces-its-own-question.md) | Each axis enforces its own question | Accepted |
| [0014](0014-the-tracked-set-is-bounded-and-seeded.md) | The tracked set is bounded and seeded | Accepted |
| [0015](0015-the-mod-ships-an-archive.md) | The mod ships an archive | Accepted; reverses the shipping constraint in [0004](0004-no-localization-archive.md) |
