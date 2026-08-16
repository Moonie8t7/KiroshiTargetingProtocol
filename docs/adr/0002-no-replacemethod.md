# 0002. No @replaceMethod

## Status

Accepted

## Context

Redscript offers three ways to attach to an existing method. `@wrapMethod` inserts a body around
the original and calls through with `wrappedMethod(...)`. `@addMethod` introduces a new method on
an existing class. `@replaceMethod` discards the original body and substitutes its own.

Only one `@replaceMethod` can be active for a given method across the whole load order. A second
mod replacing the same method either loses the race or breaks compilation, and the surviving
replacement silently reverts whatever the other mod intended. The player sees a feature that
worked yesterday stop working, with nothing in the log to explain it.

A replacement is also frozen against one game version. When CDPR changes a method body, a wrap
keeps calling the new body and inherits the fix; a replacement keeps executing the old logic and
quietly reintroduces whatever the patch corrected.

KSTP is published to an ecosystem where players routinely run hundreds of script mods.

## Decision

Use `@wrapMethod` and `@addMethod` only. `@replaceMethod` and `@replaceGlobal` appear nowhere in
the source. Where behavior cannot be achieved by wrapping, work around it or leave the feature
out and say so.

## Consequences

The mod composes. Any number of other mods can attach to the same methods KSTP attaches to, in any
order, and each still runs.

Vanilla behavior inside a wrapped method stays under CDPR's control. Game patches to that body
apply to KSTP users without a mod update.

Some behavior is out of reach. Changing what a method does partway through its body, or
suppressing a branch inside it, is not expressible as a wrap. Those cases are handled by acting on
the inputs or the outputs of the method instead: the body-part axis changes stats the native
handler reads (`Enforcement/BodyPart.reds`) rather than intercepting the handler.

Where no workaround exists, the feature is not shipped rather than shipped on a replacement.
`ANTI-MACHINE` locking human chests (ADR 0006) is one such case.
