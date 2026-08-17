// Kiroshi Smart Targeting Protocol: logging.
//
// Provides the mod's only log entry points, each prefixed with [KSTP]. Sinks are FTLog,
// FTLogWarning and FTLogError (orphans.script:53683, :66350, :66352): the only logging
// functions in the decompiled 2.31 dump, and the ones the reference corpus uses (Limited
// HUD utils.reds:11, Virtual Car Dealer CarDealer-System.reds:177). ModLog() and
// LogChannel() appear in older mod code but exist nowhere in the dump.
//
// Dependency-free: every other KSTP file may call into this one, so this file imports none.

module KSTP.Core

// True when the player has enabled verbose logging in the Debug group of Mod Settings.
// Read per call, not cached, so tracing can be turned on without a recompile.
// `new KSTPDebugConfig()` yields the saved value because Mod Settings patches class defaults
// through RTTI; see ADR 0010. Off by default.
public func KSTP_DebugLoggingEnabled() -> Bool {
  return new KSTPDebugConfig().debugLogging;
}

// Mod Settings class for the debug switch. Declared here rather than in UI/Settings.reds to
// keep this file dependency-free; a settings class is inert metadata when Mod Settings is
// absent (ADR 0010).
public class KSTPDebugConfig {

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug")
  @runtimeProperty("ModSettings.category.order", "900")
  @runtimeProperty("ModSettings.displayName", "Verbose logging")
  @runtimeProperty("ModSettings.description", "Writes detailed tracing to the game log: policy pushes, target sweeps, suppression counts and spawn-hook activity. Off by default because it logs many times a second while a smart weapon is drawn. Turn it on only to gather detail for a bug report.")
  public let debugLogging: Bool = false;
}

// Logging entry points for the whole mod. Severity selects the sink; the [KSTP] prefix is
// added here, so callers pass an undecorated message.
public class KSTPLog {

  // Startup, teardown and protocol switches. Low frequency, always emitted.
  public static func Info(msg: String) -> Void {
    FTLog(KSTPLog.Decorate(msg));
  }

  // Degraded but survivable: a gate is off, a framework is missing, an optional lookup
  // returned null. Nothing in this mod is fatal, so this is the most severe outcome a
  // normal code path reports.
  public static func Warn(msg: String) -> Void {
    FTLogWarning(KSTPLog.Decorate(msg));
  }

  // Contract violation: a game API returned something the dump says it cannot.
  public static func Error(msg: String) -> Void {
    FTLogError(KSTPLog.Decorate(msg));
  }

  // Emits only when verbose logging is on.
  public static func Debug(msg: String) -> Void {
    if KSTP_DebugLoggingEnabled() {
      FTLog(KSTPLog.Decorate("[dbg] " + msg));
    };
  }

  // Guard for callers: test this before building an interpolated string in a per-frame path,
  // otherwise the string is constructed and then discarded by Debug().
  public static func DebugEnabled() -> Bool {
    return KSTP_DebugLoggingEnabled();
  }

  private static func Decorate(msg: String) -> String {
    return "[KSTP] " + msg;
  }
}
