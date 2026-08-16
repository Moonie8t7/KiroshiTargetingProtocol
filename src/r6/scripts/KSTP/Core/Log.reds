// Kiroshi Smart Targeting Protocol: logging.
//
// Sinks are FTLog, FTLogWarning and FTLogError (orphans.script:53683, :66350, :66352).
// They are the only log entry points present in the decompiled 2.31 dump, and the
// reference corpus uses them (Limited HUD utils.reds:11, Virtual Car Dealer
// CarDealer-System.reds:177). ModLog() and LogChannel() appear in older mod code but
// exist nowhere in the dump, so KSTP does not build on them.
//
// Dependency-free by design: every other KSTP file may call into this one.

module KSTP.Core

// Master debug switch, read from the Debug group in Mod Settings.
//
// Reading the setting rather than a compiled constant means a player filing a bug report
// can turn tracing on without a recompile, which is the only way a mod author gets useful
// logs back. `new KSTPDebugConfig()` yields the value the player saved, because Mod
// Settings patches class defaults through RTTI.
//
// Off by default. With it off, KSTPLog.Debug() emits nothing and the per-frame call sites
// cost one bool read. Guard any interpolated string behind DebugEnabled() so the string is
// never built when tracing is off.
public func KSTP_DebugLoggingEnabled() -> Bool {
  return new KSTPDebugConfig().debugLogging;
}

// Declared here rather than in UI/Settings.reds because Log.reds is dependency-free by
// design and every other file may call into it. A settings class is inert metadata, so
// this costs nothing when Mod Settings is absent.
public class KSTPDebugConfig {

  @runtimeProperty("ModSettings.mod", "Kiroshi Targeting Protocol")
  @runtimeProperty("ModSettings.category", "Debug")
  @runtimeProperty("ModSettings.category.order", "900")
  @runtimeProperty("ModSettings.displayName", "Verbose logging")
  @runtimeProperty("ModSettings.description", "Writes detailed tracing to the game log: policy pushes, target sweeps, suppression counts and spawn-hook activity. Off by default because it logs many times a second while a smart weapon is drawn. Turn it on only to gather detail for a bug report.")
  public let debugLogging: Bool = false;
}

public class KSTPLog {

  // Startup, teardown and protocol switches. Low frequency, always emitted.
  public static func Info(msg: String) -> Void {
    FTLog(KSTPLog.Decorate(msg));
  }

  // A degraded but survivable condition: a gate is off, a framework is missing, an
  // optional lookup returned null. Nothing in this mod is allowed to be fatal, so
  // this is the most severe outcome a normal code path can report.
  public static func Warn(msg: String) -> Void {
    FTLogWarning(KSTPLog.Decorate(msg));
  }

  // A contract violation: a game API returned something the dump says it cannot.
  public static func Error(msg: String) -> Void {
    FTLogError(KSTPLog.Decorate(msg));
  }

  public static func Debug(msg: String) -> Void {
    if KSTP_DebugLoggingEnabled() {
      FTLog(KSTPLog.Decorate("[dbg] " + msg));
    };
  }

  // Test this before building an interpolated string inside a per-frame loop.
  // Otherwise the string is constructed and then discarded by Debug().
  public static func DebugEnabled() -> Bool {
    return KSTP_DebugLoggingEnabled();
  }

  private static func Decorate(msg: String) -> String {
    return "[KSTP] " + msg;
  }
}
