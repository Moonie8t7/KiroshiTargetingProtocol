# 0012. Blackboard delivery through the host controller

## Status

Accepted.

## Context

Two features of this mod had never run. The IFF overlay had never drawn a label, and the faction
axis had never enforced anything except at the moment the settings menu closed. Both had shipped,
both compiled without error, and both had been reported as working in earlier sessions on the
strength of code review rather than measurement.

Each depended on a blackboard listener registered against
`UI_ActiveWeaponData.SmartGunParams`:

| Registrant | Kind | Callback |
|---|---|---|
| `KSTPIFFOverlay` | `IScriptable` | `OnKSTPSmartGunParams` |
| `KSTPFactionSystem` | `ScriptableSystem` | `OnSmartGunParams` |

Both used `IBlackboard.RegisterDelayedListenerVariant`. Both returned a valid handle. Neither ever
delivered a callback.

The overlay was measured directly. A counter on the callback, reported on detach, gave the same
answer four times: `overlay detached after 0 callback(s)`, once across 8.5 minutes of continuous
smart-weapon crosshair with the registration reporting `listener=true`.

The faction system was measured indirectly, because it has no equivalent hook. `ReevaluateTracked`
has two call sites: the dead callback, and the settings and loadout reapply path, which also emits
a `sweep:` line. Across 84 `lock list:` traces in the captured logs, every one was accompanied by a
`sweep:` line at the same timestamp. Had the listener fired, its own heartbeat throttle would have
produced hundreds of unaccompanied lines.

Everything the two registrants did not share was eliminated as a cause: blackboard instance,
`ref` versus `wref` on the field, callback name, object lifetime root, and compilation. The
payload cast was proven correct by `CollectLockedTargets`, which polls the same variable with
`GetVariant` and returns live target counts.

One difference remains, and it partitions the corpus without exception. Every
`RegisterDelayedListener*` call site in the 2.31 script dump is on an ink game controller. Plain
`RegisterListener*` is used freely on components, systems and other `IScriptable` subclasses
(`senseComponent.script:335`, `vehicleComponent.script:5164`). The delayed queue is drained by the
UI traversal that services game controllers; an object outside that traversal is never called
back. The native implementation was not read, so the attribution rests on the corpus split and the
elimination above.

## Decision

Take delivery from the host controller instead of registering for it.

`CrosshairGameController_Smart_Rifl` registers this exact variable at
`crosshairController_Smart_Rifle.script:67` and handles it at `:91`. That listener works, its
lifetime is already the lifetime the overlay wants, and this mod already wraps two methods on the
class. `UI/Overlay.reds` wraps a third, `OnSmartGunParams`, and forwards the payload to the
overlay and to the faction system.

Both registrations are removed. Neither module registers a blackboard listener of any kind.

`CrosshairGameController_BlackwallForce` extends this controller and calls
`super.OnSmartGunParams`, so wrapping the base covers the Blackwall crosshair.

## Consequences

The overlay draws. Twelve attach and detach pairs in the first session after the change reported
between 44 and 855 callbacks each, against zero before it.

Enforcement runs continuously rather than only on a settings change. In the same session, 388 of
412 enforcement passes were driven by the weapon rather than by the reapply path. A faction
unticked in the menu now refuses targets encountered later, elsewhere, with no further menu
interaction. That was not previously possible, and it is the capability the faction axis was
written to provide.

A registration leak closed as a side effect. The overlay had logged 17 attaches against 4 detaches
in one session, each unmatched attach leaving a live registration on a global blackboard pointing
at a discarded widget tree. With no registration, there is nothing to leak; attaches and detaches
now balance exactly.

The mod is more tightly bound to `CrosshairGameController_Smart_Rifl` than before. A future build
that renames or restructures that controller removes both features at once rather than one. This
is accepted: the alternative was a registration that silently did nothing, which is worse than a
dependency that fails loudly.

Two instrumentation lessons are recorded here because they cost more than the bug did.

The first counter written to answer this question reset on every attach and reported only every
sixtieth callback. A session shorter than sixty callbacks produced no output, which is identical
to the output produced by a listener that never fires. The measurement could not distinguish the
two states it existed to distinguish. A trace intended to prove absence must report its first
event, not a sample of its steady state.

The second is that neither of these features was ever exercised by the test that was supposed to
cover it. The overlay was assessed by looking for labels on screen, which is indistinguishable
from a missing smart weapon; the faction axis was assessed immediately after a settings change,
which is the one moment the broken path was bypassed. Both defects survived several sessions of
deliberate testing for that reason.
