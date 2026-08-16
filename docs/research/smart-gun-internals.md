# Smart-weapon targeting internals, game build 2.31

Reference for anyone modifying or extending smart-gun behavior from redscript.

Every claim below cites `file:line` against the decompiled 2.31 script dump at
`<decompiled-scripts>`, and every cited line has been opened and read. Where the dump
cannot settle a question, the text says so.

The behavioral results that back the stat sections are in `experiments.md`. Raw capture from the
sessions that produced them is in `docs/evidence/`.

---

## 1. The acquisition pipeline and its script surface

Smart-gun acquisition runs in C++. Script sees the stats it consumes and the UI payload it
publishes, and nothing in between.

| Stage | What it decides | Script surface |
|---|---|---|
| Candidate gathering | Which entities enter the smart-gun target set | None. Range is data-driven through `SmartGunTargetAcquisitionRange` (`orphans.script:2773`) |
| Per-candidate acceptance | Whether a gathered entity may be engaged | None. Section 2 |
| Component selection | Which body part on a candidate carries the lock | `SmartGunTrack*Components` on the weapon's item-data stats object (`orphans.script:2784-2791`). Section 3 |
| Lock timing | How long a component takes to go `Locking` -> `Locked` | `SmartGunTimeToLock*ComponentMultiplier` on the target's stats object (`orphans.script:2775-2781`). Section 4 |
| Lock budget | How many targets may be held at once | `SmartGunAdsMaxLockedTargets` (`orphans.script:2727`), `SmartGunHipMaxLockedTargets` (`orphans.script:2739`) |
| Component fallback | What happens when no component class qualifies | None. A raw head slot, `cyberpunk\items\weapon.script:1533`. Section 6 |
| UI publication | The live target list shown to the player | Read-only, blackboard `UI_ActiveWeaponData.SmartGunParams` (`core\blackboard\blackboardDefinitions.script:1601`). Section 5 |
| Projectile guidance | Homing behavior after the shot | `gameprojectileWeaponParams` fields set in `AIWeapon.Fire` (`weapon.script:1527-1531`); the sample projectile reads `SmartTargetingShouldNotDisableCollision` off the target (`samples\sampleSmartBullet.script:542`) |

Two stages carry a usable control surface: component selection and lock timing. Both are stat
reads, so both are reachable by adding a stat modifier. Everything else is closed.

---

## 2. TargetingSystem is sealed

```
orphans.script:22381   public abstract final importonly class TargetingSystem extends ITargetingSystem {
orphans.script:22383     public final native func GetTargetParts(instigator, query, out parts) -> Bool;
orphans.script:22385     public final native func GetObjectClosestToCrosshair(...) -> ref<GameObject>;
orphans.script:22387     public final native func GetComponentClosestToCrosshair(...) -> ref<IPlacedComponent>;
orphans.script:22389     public final native func GetTargetClosestByDistance(...) -> ref<GameObject>;
```

Three properties of that declaration each independently close the obvious approach:

| Property | Consequence |
|---|---|
| `importonly` | The class body lives in C++. There is no script method to wrap |
| `final` | The class cannot be subclassed to intercept behavior |
| `native` on every member | redscript annotations cannot patch native functions |

**There is no per-candidate veto available from redscript.** No script code sees each candidate and
gets to reject it. Any design premised on filtering the candidate list stops here, which is why the
working mechanisms are stat-based.

Calling a native function is unaffected by any of this. `StatsSystem.AddModifier` and
`RemoveModifier` (`orphans.script:16943`, `:16949`) are called normally.

### The two near misses

`AddIgnoredLookAtEntity` / `RemoveIgnoredLookAtEntity` (`orphans.script:22443`, `:22445`) look like
a per-entity veto and are callable. They do not affect smart-gun acquisition. See `experiments.md`.

`TargetFilter_Script` (`core\systems\targetingSystem.script:13`) is a `native class` whose filter
hooks are declared without `native`:

```
core\systems\targetingSystem.script:25   public func PreFilter(const defaultPos: script_ref<Vector4>) -> Void;
core\systems\targetingSystem.script:27   public func Filter(hitInfo: TargetHitInfo, workingState: ref<TargetFilterResult>) -> Void;
core\systems\targetingSystem.script:29   public func PostFilter() -> Void;
```

Those are script functions the engine can dispatch to, registered through
`RegisterLookAtFilter` (`orphans.script:22439`) and released through `UnregisterLookAtFilter`
(`:22441`). The registration path is named for LookAt, like the ignore list. Whether the smart-gun
acquisition stage runs these filters at all is not settled by the dump and has not been
established in game.

---

## 3. The weapon-side track stats

Eight consecutive entries in `gamedataStatType`:

| Stat | Value | Governs |
|---|---|---|
| `SmartGunTrackBreachComponents` | 1411 | Breach points |
| `SmartGunTrackChestComponents` | 1412 | Torso |
| `SmartGunTrackHeadComponents` | 1413 | Head |
| `SmartGunTrackLegComponents` | 1414 | Legs |
| `SmartGunTrackMechanicalComponents` | 1415 | Mechanical parts on drones and mechs |
| `SmartGunTrackMultipleEntitiesInADS` | 1416 | Multi-target lock while aiming |
| `SmartGunTrackVehicleComponents` | 1417 | Vehicle parts |
| `SmartGunTrackWeakSpotComponents` | 1418 | Weak spots |

Source: `orphans.script:2784-2791`.

These are counts, not booleans. A value of `3` on Chest means three chest components may carry a
lock. Driving one to `0` removes that class from selection.

### Which stats object they live on

The handler reads the **held weapon's item data** stats object,
`weapon.GetItemData().GetStatsObjectID()`, not the weapon entity's. The vanilla effector path
resolves the same object:

```
core\gameplay\effector.script:31   switch applicationTarget {
...:32     case n"Weapon":
...:33       weapon = ScriptedPuppet.GetActiveWeapon(effectorOwner);
...:37       targetID = weapon.GetItemData().GetStatsObjectID();
```

Writing to the weapon entity's `StatsObjectID` instead has no effect on lock behavior.

### Vanilla precedent

`Items.KiroshiOpticsFragment1` applies `SmartGunTrackLegComponentsModifier` to the held weapon,
conditioned on `Prereqs.SmartWeaponHeldPrereq`. The item record exists in the dump
(`core\systems\craftingSystem.script:1836`), and its recipe is hidden along with fragments 2
through 5 (`:1837-1840`). The record and prereq names are TweakDB data with no script reference,
so they are checkable with a TweakDB browser rather than in the script dump.

The effector chain that carries it is script-visible end to end:

```
orphans.script:48890   public importonly class ApplyStatGroupEffector_Record extends Effector_Record {
...:48892                public final native func StatGroup() -> wref<StatModifierGroup_Record>;
...:48896                public final native func ApplicationTarget() -> CName;

core\gameplay\effectors\applyStatGroupEffector.script:38-46
                       Initialize() reads StatGroup, applicationTarget and removeWithEffector;
                       reapplyOnWeaponChange is read only when applicationTarget is n"Weapon" (:42-44)
core\gameplay\effectors\applyStatGroupEffector.script:48-54
                       Uninitialize() removes the group when removeWithEffector is set
```

Modifying a smart-gun track stat on a held weapon is a shipped vanilla pattern.

### Applying and removing a modifier

The idiom is two calls:

```swift
this.m_tutorialZeroCapacityModifier = RPGManager.CreateStatModifier(
    gamedataStatType.HumanityAllocated, gameStatModifierType.Additive, -currentAllocatedCapacity);
this.m_statsSystem.AddModifier(Cast<StatsObjectID>(this.m_player.GetEntityID()),
                               this.m_tutorialZeroCapacityModifier);
```

(`cyberpunk\UI\fullscreen\ripperdoc\ripperdoc.script:517-518`.)

Three constraints follow:

- `RPGManager.CreateStatModifier(statType, modifierType, value)` is the factory. Constructing
  `gameStatModifierData` by hand is unnecessary.
- A `StatsObjectID` comes from `Cast<StatsObjectID>(entityID)`. The same cast is used against an
  NPC at `samples\sampleSmartBullet.script:542`.
- `RemoveModifier` (`orphans.script:16949`) matches on the modifier object, not on the stat type.
  The reference must be stored when the modifier is applied, or it cannot be removed.

---

## 4. The target-side lock-time multipliers

Seven entries, one per component class:

| Stat | Value |
|---|---|
| `SmartGunTimeToLockBreachComponentMultiplier` | 1402 |
| `SmartGunTimeToLockChestComponentMultiplier` | 1403 |
| `SmartGunTimeToLockHeadComponentMultiplier` | 1404 |
| `SmartGunTimeToLockLegComponentMultiplier` | 1405 |
| `SmartGunTimeToLockMechanicalComponentMultiplier` | 1406 |
| `SmartGunTimeToLockVehicleComponentMultiplier` | 1407 |
| `SmartGunTimeToLockWeakSpotComponentMultiplier` | 1408 |

Source: `orphans.script:2775-2781`.

The lock timer resolves these from the **target NPC's** stats object. That makes them the only
per-entity control in the pipeline: a large multiplier on one NPC holds that NPC at `Locking`
while every other candidate locks normally.

The mechanism is preventive. It stops a lock from completing; it does not release a lock that has
already completed. Enforcement therefore has to reach a candidate before the lock timer finishes,
not after.

Scope is the target, not the observer. Every smart weapon in the world, including an ally's, is
impaired against a suppressed NPC.

The family is not uniformly initialized in vanilla, and the trap this creates is in
`experiments.md`.

---

## 5. The live target list

The native handler publishes what it is currently tracking on a blackboard.

```
core\blackboard\blackboardDefinitions.script:1595   public class UI_ActiveWeaponDataDef extends BlackboardDefinition {
...:1601     public let SmartGunParams: BlackboardID_Variant;
```

Payload, `orphans.script:54441-54455`:

| Field | Type |
|---|---|
| `targets` | `[smartGunUITargetParameters]` |
| `sight` | `smartGunUISightParameters` |
| `crosshairPos` | `Vector2` |
| `hasRequiredCyberware` | `Bool` |
| `timeToRemoveOccludedTarget` | `Float` |
| `timeToLock` | `Float` |
| `timeToUnlock` | `Float` |

Per target, `orphans.script:54420-54438`:

| Field | Type |
|---|---|
| `pos` | `Vector2` |
| `state` | `gamesmartGunTargetState` |
| `distance` | `Float` |
| `accuracy` | `Float` |
| `isLocked` | `Bool` |
| `timeLocking` | `Float` |
| `timeUnlocking` | `Float` |
| `entityID` | `EntityID` |
| `attachedBoneName` | `CName` |

State values, `orphans.script:8702-8708`:

| Value | Meaning |
|---|---|
| `Visible = 0` | In view, not yet a candidate |
| `Targetable = 1` | Eligible for a lock |
| `Locking = 2` | Lock timer running |
| `Locked = 3` | Lock complete |
| `Unlocking = 4` | Lock decaying |

`entityID` makes each entry classifiable. `attachedBoneName` identifies which body part the lock
landed on, so a HUD can distinguish a head lock from a chest lock rather than reporting only that
a lock exists.

### Retrieval

The Basilisk HUD is the vanilla pattern:

```
cyberpunk\UI\hud\custom\hud_panzer.script:130   this.m_weaponBlackboard = bbSys.Get(GetAllBlackboardDefs().UI_ActiveWeaponData);
...:131   if IsDefined(this.m_weaponBlackboard) {
...:132     this.m_weaponParamsListenerId = this.m_weaponBlackboard.RegisterDelayedListenerVariant(
                GetAllBlackboardDefs().UI_ActiveWeaponData.SmartGunParams, this, n"OnSmartGunParams");
```

Teardown at `:149-150`:

```
hud_panzer.script:149   if IsDefined(this.m_weaponBlackboard) {
...:150     this.m_weaponBlackboard.UnregisterDelayedListener(
              GetAllBlackboardDefs().UI_ActiveWeaponData.SmartGunParams, this.m_weaponParamsListenerId);
```

Two consequences for any consumer:

- The listener is **delayed**. It fires on the UI tick rather than the game tick, so the payload
  trails the simulation. Enforcement driven off this listener is reactive by construction and can
  arrive after a lock has already completed.
- `hasRequiredCyberware` gates the whole payload. Without Smart Link installed the target list is
  legitimately empty.

---

## 6. The head-slot fallback

Disabling every component class does not stop engagement.

`AIWeapon.Fire` (`cyberpunk\items\weapon.script:1469`) picks the best component on the target and
falls through to a bare head slot when there is none:

```
weapon.script:1522   bestTargetingComponent = GameInstance.GetTargetingSystem(weaponOwner.GetGame())
                       .GetBestComponentOnTargetObject(..., target, TargetComponentFilterType.Shooting);
weapon.script:1525   if IsDefined(bestTargetingComponent) {
weapon.script:1526     positionProvider = ... CreatePlacedComponentPositionProvider(bestTargetingComponent);
weapon.script:1532   } else {
weapon.script:1533     positionProvider = ... IPositionProvider.CreateSlotPositionProvider(target, n"Head");
```

Zeroing every `SmartGunTrack*Components` stat therefore produces a lock on a raw head slot rather
than a refusal (`experiments.md`, weapon-side track stats). A design that wants "do not engage this
target at all" has to use the target-side lock-time mechanism in section 4, not an empty component
set.

---

## 7. Classification call chains

The pipeline offers no classification of its own. Anything that treats one target differently from
another has to derive it from the entity.

### Affiliation

```
cyberpunk\puppet\scriptedPuppet.script:1114   GetRecord() -> ref<Character_Record>
orphans.script:16188                          public importonly class Character_Record
orphans.script:16278                            public final native func Affiliation() -> wref<Affiliation_Record>
orphans.script:27834                          public importonly class Affiliation_Record
orphans.script:27848                            public final native func EnumName() -> CName
orphans.script:27852                            public final native func Type() -> gamedataAffiliation
orphans.script:4404                           enum gamedataAffiliation
```

`EnumName()` returns a `CName` and `Type()` returns the compiled enum. Matching on the name
survives factions added by other mods, which cannot extend a compiled RTTI enum.

Android variants are separate enum values from their parent faction:

```
orphans.script:4415   Maelstrom = 10,
orphans.script:4416   MaelstromAndroid = 11,
```

A filter matching only `Maelstrom` lets every Maelstrom android through. Any faction match must
fold android variants into the parent faction. Androids are separately identifiable at
`scriptedPuppet.script:1122` (`IsAndroid()`).

### Attitude

```
core\entity\gameObject.script:451   public final static func GetAttitudeTowards(const first, const second) -> EAIAttitude
...:454     if first == null || second == null { return EAIAttitude.AIA_Neutral; };
...:457     fa = first.GetAttitudeAgent();
...:458     fb = second.GetAttitudeAgent();
...:459     if fa != null && fb != null { return fa.GetAttitudeTowards(fb); };
...:462     return EAIAttitude.AIA_Neutral;
```

The instance overload at `:465` carries the identical fallback at `:474`.

`GameObject.GetAttitudeAgent()` returns `null` on the base class (`gameObject.script:430-432`).
Only puppets, vehicles, sensor devices and muppets override it (`scriptedPuppet.script:1086`,
`core\gameplay\vehicles.script:514`, `cyberpunk\devices\core\sensorDevice.script:452`,
`cyberpunk\muppet\muppet.script:22`).

Drones, turrets and most devices are lockable (`SmartGunTrackMechanicalComponents` and
`SmartGunTrackVehicleComponents` exist for them) and have no attitude agent. Every one of them
reads back as `AIA_Neutral`, indistinguishable from a neutral NPC with an attitude agent. A
hostile-only filter
built on attitude alone refuses every drone and turret in the game while appearing correct on
humans. Track whether the attitude is known separately from its value, and branch on whether the
object is a puppet before consulting it.

Attitude is group-relational and changes during combat. It cannot be cached.

### NPC type

```
scriptedPuppet.script:1118   GetNPCType() -> gamedataNPCType   (GetRecord().CharacterType().Type())
scriptedPuppet.script:1122   IsAndroid()
scriptedPuppet.script:1126   IsMech()
scriptedPuppet.script:1130   IsHuman()
scriptedPuppet.script:1138   IsHumanoid()      (Human or Android)
scriptedPuppet.script:1147   IsMechanical()    (Android, Drone, Mech, or the IsMechanical ability)
```

All of these route through `GetRecord()`, so a null record takes every one of them down. Guard the
record once and reuse it.

### Rarity

```
orphans.script:16600         GetNPCRarity() -> gamedataNPCRarity
orphans.script:16602         GetNPCRarityRecord() -> ref<NPCRarity_Record>
scriptedPuppet.script:1310   IsMaxTac() -> GetNPCRarity() == gamedataNPCRarity.MaxTac
```

### Role flags, and what they are not

| Call | What it actually reads | Site |
|---|---|---|
| `IsPrevention()` | `IsCharacterPolice()`, nothing more | `scriptedPuppet.script:1553-1555` |
| `IsCharacterPolice()` | the `m_isPolice` record flag | `scriptedPuppet.script:1398-1400` |
| `IsCharacterCivilian()` | the `m_isCivilian` record flag | `scriptedPuppet.script:1394-1396` |
| `IsNetrunnerPuppet()` | a stat read of `IsNetrunnerArchetype` | `scriptedPuppet.script:1143-1145` |
| `IsCrowd()` | the record flag **or** a live `CrowdMemberComponent` query | `scriptedPuppet.script:1425-1427` |

`IsPrevention()` reads like a query against the wanted-level system. It is one boolean off the
character record. An NPC with NCPD affiliation can fail it, because affiliation and the police flag
are set independently. Cross-check affiliation before assigning a police classification.

`IsNetrunnerPuppet()` reads like a record flag and is a stat. Any mod, including this one, can add
a modifier to a stat, so a cached netrunner classification can go stale.

### What is safe to cache

| Axis | Cacheable per `EntityID` | Reason |
|---|---|---|
| Affiliation | Yes | Fixed at spawn, off the character record |
| NPC type | Yes | Fixed at spawn, off the character record |
| Rarity | Yes | Fixed at spawn, off the character record |
| Netrunner flag | With care | A stat, so writable at runtime |
| Crowd flag | With care | Consults a live component |
| Attitude | No | Group-relational and mutable |

---

## 8. Citation index

All paths relative to `<decompiled-scripts>`.

| What | Where |
|---|---|
| `TargetingSystem`, abstract final importonly, all-native | `orphans.script:22381-22389` |
| `ProcessLookAtFilter` / `RegisterLookAtFilter` / `UnregisterLookAtFilter` | `orphans.script:22437`, `:22439`, `:22441` |
| `AddIgnoredLookAtEntity` / `RemoveIgnoredLookAtEntity` | `orphans.script:22443`, `:22445` |
| `TargetFilter_Script`, native class with script-side `Filter()` | `core\systems\targetingSystem.script:13`, `:25-29` |
| `SmartGunTimeToLock*ComponentMultiplier` | `orphans.script:2775-2781` |
| `SmartGunTrack*Components` and `MultipleEntitiesInADS` | `orphans.script:2784-2791` |
| `SmartGunTargetAcquisitionRange` | `orphans.script:2773` |
| `SmartGunAdsMaxLockedTargets` / `SmartGunHipMaxLockedTargets` | `orphans.script:2727`, `:2739` |
| `SmartTargetingShouldNotDisableCollision`, and a target-side read | `orphans.script:2798`; `samples\sampleSmartBullet.script:542` |
| `StatsSystem.AddModifier` / `RemoveModifier` | `orphans.script:16943`, `:16949` |
| `RPGManager.CreateStatModifier` plus `AddModifier` idiom | `cyberpunk\UI\fullscreen\ripperdoc\ripperdoc.script:517-518` |
| `applicationTarget: Weapon` resolves to the item-data stats object | `core\gameplay\effector.script:26-38` |
| `ApplyStatGroupEffector_Record` | `orphans.script:48890-48899` |
| Effector init and teardown | `core\gameplay\effectors\applyStatGroupEffector.script:38-46`, `:48-54` |
| `Items.KiroshiOpticsFragment1` exists; recipes hidden | `core\systems\craftingSystem.script:1836-1840` |
| `AIWeapon.Fire` and the raw head-slot fallback | `cyberpunk\items\weapon.script:1469`, `:1522-1533` |
| `UI_ActiveWeaponDataDef.SmartGunParams` | `core\blackboard\blackboardDefinitions.script:1595`, `:1601` |
| `smartGunUITargetParameters` | `orphans.script:54420-54438` |
| `smartGunUIParameters` | `orphans.script:54441-54455` |
| `gamesmartGunTargetState` | `orphans.script:8702-8708` |
| Blackboard register and unregister pattern | `cyberpunk\UI\hud\custom\hud_panzer.script:130-132`, `:149-150` |
| `EnableSmartGunHandlerEvent` | `orphans.script:61871` |
| `GetAttitudeTowards`, static and instance, both Neutral-fallback | `core\entity\gameObject.script:451-463`, `:465-475` |
| `GetAttitudeAgent()` returns null on the base class | `core\entity\gameObject.script:430-432` |
| Attitude-agent overrides | `cyberpunk\puppet\scriptedPuppet.script:1086`; `core\gameplay\vehicles.script:514`; `cyberpunk\devices\core\sensorDevice.script:452`; `cyberpunk\muppet\muppet.script:22` |
| `Character_Record.Affiliation()` | `orphans.script:16188`, `:16278` |
| `Affiliation_Record.EnumName()` / `.Type()` | `orphans.script:27834`, `:27848`, `:27852` |
| `gamedataAffiliation`, Maelstrom and MaelstromAndroid | `orphans.script:4404`, `:4415`, `:4416` |
| `GetRecord()` / `GetNPCType()` / `IsAndroid()` | `cyberpunk\puppet\scriptedPuppet.script:1114`, `:1118`, `:1122` |
| `IsMech()` / `IsHuman()` / `IsHumanoid()` / `IsMechanical()` | `scriptedPuppet.script:1126`, `:1130`, `:1138`, `:1147` |
| `IsNetrunnerPuppet()`, a stat read | `scriptedPuppet.script:1143-1145` |
| `IsMaxTac()` / `IsCharacterCivilian()` / `IsCharacterPolice()` / `IsCrowd()` | `scriptedPuppet.script:1310`, `:1394`, `:1398`, `:1425` |
| `IsPrevention()` == `IsCharacterPolice()` | `scriptedPuppet.script:1553-1555` |
| `GetNPCRarity()` / `GetNPCRarityRecord()` | `orphans.script:16600`, `:16602` |
