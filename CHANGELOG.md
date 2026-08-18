# Changelog

Notable changes to the Kiroshi Smart Targeting Protocol. Versions follow
[semantic versioning](https://semver.org/); the version itself lives in `VERSION`.

## 0.1.0 - unreleased

First release. Everything below is new.

### The implant

A Frontal Cortex cyberware, the Kiroshi IFF Targeting Coprocessor, in eleven grades from Common to
Legendary++. Capacity costs 6 at every grade, matching the vanilla convention; only the price
scales. Sold by ripperdocs.

Fitting it is what turns the mod on. With no coprocessor, nothing is enforced and the overlay does
not draw.

### Targeting protocols

Six presets covering what a smart weapon will lock onto: `AUTO`, `PRECISION`, `CRIPPLE`,
`ANTI-MACHINE`, `ORGANIC` and `SURGICAL`. `AUTO` is byte-for-byte vanilla, so the mod costs nothing
until you choose otherwise.

Each protocol decides two independent questions: which body-part classes a lock may land on, and
which factions may be locked at all. Cycle them with `[`, or from the settings menu; the two stay in
step.

### Faction and threat filtering

Refuse locks on chosen factions. NCPD, Trauma Team, Aldecaldos and Afterlife mercs are unticked by
default, so the shipped configuration stops you gunning down the police by reflex. Works at every
grade rather than being gated behind the tier ladder.

Vehicles are excluded outright when the Vehicle class is off, which is the one class that can be
removed from the candidate list rather than merely slowed.

### The IFF overlay

Labels every target the smart gun is tracking, marking it `PERMIT` or `REFUSE`. Visibility is
configurable: always, while aiming, or only while `]` is held. It requires the coprocessor, so its
presence is also a direct signal that the mod is installed and running.

### Configuration

Every option is exposed through Mod Settings, with compiled defaults that stand when the framework
is absent. Both hotkeys are rebindable through Input Loader.

### Known limitations

- A denied target still draws a bracket that never completes. Candidate selection is native and
  exposes no per-candidate veto.
- Unticking every class a target carries does not exclude it. The class mask decides where a lock
  lands, not whether one happens, so `ANTI-MACHINE` cannot refuse people.
- Faction suppression is target-scoped, so an allied NPC firing a smart weapon at a target you have
  denied is impaired in the same way.
- Display strings are English in every locale.
- Turning off `Allow civilians` changes little you can see, because civilians are not smart-gun
  candidates until something makes them hostile.

### Testing scope

Developed and tested on one machine: Windows 11, GOG build 2.31, alongside roughly 300 other mods.

Everything in the feature list above was exercised in play. The eleven-grade upgrade chain was
verified statically rather than by playing it, and the mod compiles cleanly with and without each
optional framework, so a missing one cannot break a player's script load order.

Not tested: a clean install with only the required frameworks, and the observable behaviour when
each optional framework is absent. Those degrade cosmetically by design and the code paths compile,
but none has been watched happen. `README.md` lists the specifics.

### Requirements

RED4ext, redscript with cybercmd, and TweakXL are required. Mod Settings, Input Loader, Codeware and
ArchiveXL are each optional and degrade to a documented fallback. Built and tested against game
build 2.31.
