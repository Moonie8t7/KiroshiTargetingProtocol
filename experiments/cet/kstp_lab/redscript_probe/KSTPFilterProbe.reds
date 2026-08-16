// KSTP Lab :: E-FILTER redscript probe
//
// PROBE ONLY. This is NOT part of the shipping mod and must not be merged into
// src/r6/scripts/KSTP/. Copy it into r6/scripts/ only while running E-FILTER, then
// delete it. It is kept next to the CET rig so the two halves of one experiment stay
// together.
//
// WHY THIS FILE EXISTS
// CET's NewProxy builds an IScriptable-derived proxy object; it cannot declare a subclass
// of a native class. TargetFilter_Script (targetingSystem.script:13-34) declares
// PreFilter / Filter / PostFilter as script-side methods, so supplying a real Filter()
// body requires a script-side class declaration - i.e. this file. The CET rig can only
// Observe the base class and count invocations, which is enough to decide whether the
// lead is alive but not enough to actually veto a candidate.
//
// HOW TO USE IT FROM THE CET CONSOLE
//   probe = Game.KSTP_FilterProbe_Make()
//   print(Game.KSTP_FilterProbe_Control(Game.GetPlayer(), probe))
//   -- aim at an NPC, then:
//   print(Game.KSTP_FilterProbe_Register(Game.GetPlayer(), probe))
//   -- play for ten seconds, then:
//   print(Game.KSTP_FilterProbe_Summary(probe))
//   print(Game.KSTP_FilterProbe_Unregister(Game.GetPlayer(), probe))
//
// Deliberately NOT in a `module` block: module-scoped free functions are awkward to reach
// from CET, and the KSTP_ prefix already satisfies the contract's namespace rule.
//
// Contract compliance: no @replaceMethod, no `native func` of its own, nothing mutated on
// a world entity, and Unregister undoes Register.

// UNVERIFIED: subclassing the native class TargetFilter_Script from redscript. The parent
// is `public native class` (not `importonly`), and its PreFilter/Filter/PostFilter are
// declared as plain script funcs, which is the shape redscript can override - but no
// shipping mod in the reference corpus does this, so it is unproven on 2.31.
public class KSTPFilterProbe extends TargetFilter_Script {

  public let preCount: Int32;
  public let filterCount: Int32;
  public let postCount: Int32;
  public let lastHitID: EntityID;
  public let ticket: TargetFilterTicket;
  public let registered: Bool;

  public func PreFilter(const defaultPos: script_ref<Vector4>) -> Void {
    this.preCount += 1;
  }

  // TargetHitInfo fields verified at orphans.script:50757-50774.
  public func Filter(hitInfo: TargetHitInfo, workingState: ref<TargetFilterResult>) -> Void {
    this.filterCount += 1;
    this.lastHitID = hitInfo.entityId;
  }

  public func PostFilter() -> Void {
    this.postCount += 1;
  }

  public func Reset() -> Void {
    this.preCount = 0;
    this.filterCount = 0;
    this.postCount = 0;
  }

  public func Summary() -> String {
    return "pre=" + ToString(this.preCount)
      + " filter=" + ToString(this.filterCount)
      + " post=" + ToString(this.postCount)
      + " lastHit=" + EntityID.ToDebugString(this.lastHitID)
      + " registered=" + ToString(this.registered);
  }
}

public static func KSTP_FilterProbe_Make() -> ref<KSTPFilterProbe> {
  return new KSTPFilterProbe();
}

// The CONTROL. Calls the native entry point directly (orphans.script:22437). If the
// counters stay at zero here, the native side never dispatches into script and no amount
// of registration will change that.
public static func KSTP_FilterProbe_Control(player: ref<GameObject>, probe: ref<KSTPFilterProbe>) -> String {
  if !IsDefined(player) || !IsDefined(probe) {
    return "KSTP: bad arguments";
  }
  probe.Reset();
  GameInstance.GetTargetingSystem(player.GetGame()).ProcessLookAtFilter(player, probe);
  return "KSTP CONTROL ProcessLookAtFilter -> " + probe.Summary();
}

// orphans.script:22439 RegisterLookAtFilter -> TargetFilterTicket
public static func KSTP_FilterProbe_Register(player: ref<GameObject>, probe: ref<KSTPFilterProbe>) -> String {
  if !IsDefined(player) || !IsDefined(probe) {
    return "KSTP: bad arguments";
  }
  if probe.registered {
    return "KSTP: already registered";
  }
  probe.Reset();
  probe.ticket = GameInstance.GetTargetingSystem(player.GetGame()).RegisterLookAtFilter(player, probe);
  probe.registered = true;
  return "KSTP: registered, now play for ten seconds and call Summary";
}

// orphans.script:22441 UnregisterLookAtFilter. Rule 4: this must always be called.
public static func KSTP_FilterProbe_Unregister(player: ref<GameObject>, probe: ref<KSTPFilterProbe>) -> String {
  if !IsDefined(player) || !IsDefined(probe) {
    return "KSTP: bad arguments";
  }
  if !probe.registered {
    return "KSTP: nothing registered";
  }
  GameInstance.GetTargetingSystem(player.GetGame()).UnregisterLookAtFilter(player, probe.ticket);
  probe.registered = false;
  return "KSTP: unregistered -> " + probe.Summary();
}

public static func KSTP_FilterProbe_Summary(probe: ref<KSTPFilterProbe>) -> String {
  if !IsDefined(probe) {
    return "KSTP: no probe";
  }
  return "KSTP " + probe.Summary();
}
