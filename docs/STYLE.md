# Source and documentation style

Binding for every shipped file. The mod is published on Nexus and GitHub; source is read by
strangers with no context on how it was built.

## Prose rules

**Comments explain the code as it stands.** They state intent, constraint, and the reason a
non-obvious choice was made. They never narrate how the code came to be written, what was tried
first, or what somebody discovered. A reader wants to know why the line is there, not its history.

Banned outright:

| Banned | Use instead |
|---|---|
| Curly quotes `' ' " "` | straight ASCII `'` and `"` |
| First person: `I`, `we`, `my`, `our`, `us` | passive or imperative: "the handler reads", "prune the ledger" |
| Dated notes: `CONFIRMED PASS 2026-08-16`, `BISECT`, `REMOVED 2026-...` | state the current fact; history belongs in git |
| `deliberately`, `genuinely`, `notably`, `crucially`, `importantly` | delete the adverb, or say the thing plainly |
| `Note that`, `It is worth noting`, `Worth flagging` | delete the preamble and state the point |
| `observed in play`, `measured in play`, `turned out to be` | state the fact: "the handler does not consult it" |

**ASCII only** in source files. Straight quotes, `->` rather than an arrow character, no
box-drawing, no emoji, and no accented characters unless part of a real identifier.

**Spelling: US English** throughout, matching the game and the wider mod ecosystem
(`behavior`, `color`, `initialize`, `analyze`).

## Comment density

Comment the non-obvious. Do not comment the obvious.

- A file header states what the module owns and what it must not do.
- A function comment is warranted when the function has a constraint, an ordering requirement,
  a failure mode, or a reason it is not written the simpler way.
- A line comment is warranted when a line would look wrong to a competent reader.
- Every reference to game internals cites `file.script:line` so the claim can be checked.
- No comment restates its own code. `// increment the counter` above `i += 1` is noise.

Target: a reader who knows redscript but not this mod should be able to modify any file safely
after reading its header and the comments in the function they are changing.

## Log output

Player-visible logs are `KSTPLog.Info`. Diagnostics are `KSTPLog.Debug` behind
`KSTP_DebugLoggingEnabled()`. A shipped build must not log per-frame or per-entity at Info level.
Messages are lowercase, factual, and contain the numbers a bug report needs.

## Markdown docs

Same prose rules. Additionally:

- A doc that exists to record a decision states the decision and the evidence, not the process.
- No "we found", "it turned out", "after investigation".
- Tables over prose for anything with more than three parallel facts.
- Code fences carry a language tag.
