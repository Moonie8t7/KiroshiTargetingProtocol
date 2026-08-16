# 0001. No native plugin

## Status

Accepted

## Context

Smart-gun target acquisition runs entirely in native code. `TargetingSystem` is declared
`abstract final importonly` (`orphans.script:22381`) and every member on it is `native`, so
redscript can call into it but cannot patch it, subclass it, or observe the candidate list it
builds.

The native candidate filter is the only place a true per-candidate veto could live: the one point
in the pipeline that sees each prospective target and can reject it before any lock timer starts.
Reaching that point means hooking the native function from a RED4ext C++ plugin.

A plugin is therefore the only route to a capability the stat-based design cannot express. The
question is what shipping one costs the player.

## Decision

Ship pure redscript plus TweakXL. No RED4ext C++ plugin of the mod's own, and no `native func`
declarations in KSTP's redscript.

## Consequences

The per-candidate veto is unavailable. Every mechanism in the mod is built from stat modifiers
applied through `StatsSystem`, which is native but callable.

**Failure modes avoided.** A native plugin binds to addresses inside `Cyberpunk2077.exe`. RED4ext
resolves those addresses by hashing the compiled function body, so when CDPR recompiles a function
its hash does not move to a new address, it stops resolving. There is no fallback address to try
and no partial match to recover from. The address is simply gone until a maintainer locates the
function again in a stripped multi-megabyte binary with no symbols and re-derives the hash.

The two ways a plugin can respond to that are both worse than degrading:

| Response | Result for the player |
|---|---|
| Fail loudly at load | A message box naming the mod, then process termination. The game does not start. |
| Pin the supported runtime version and decline to load | The plugin never registers its exported functions, so every `native func` declared in redscript is an unresolved symbol. Redscript compilation fails for the entire load order, not only KSTP. One absent DLL takes down every other redscript mod on the install. |

A redscript mod degrades instead. A stat modifier whose stat no longer has an effect leaves
vanilla behavior in place and the game keeps running. A wrapped method whose signature changed
reports a named error in `redscript_rCURRENT.log` that points at the file and line to fix.

**Ongoing cost avoided.** A plugin needs a C++ toolchain, a compiled binary per game version, and
a reverse-engineering pass per patch to re-derive the hooks. Every one of those is a dependency
only a subset of contributors can satisfy, and the support load ("it crashes on launch") falls on
the player.

**Cost accepted.** Denying a specific target has to be done through the faction axis
(ADR 0003), which prevents a lock rather than vetoing a candidate, and is target-scoped rather
than observer-scoped.
