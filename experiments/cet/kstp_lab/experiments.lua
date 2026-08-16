-- KSTP Lab :: experiments.lua
--
-- The five experiments, with no ImGui in sight. Each one exposes apply/clear/measure
-- entry points; init.lua drives them and draws the results.
--
-- Contract rule 4 ("restore what you mutate") applies to this file above all others:
-- every stat modifier, every ignored entity, the filter ticket and the aim-assist config
-- are tracked in Exp.state and unwound by Exp.teardown(), which init.lua calls on
-- onShutdown and on the panic button.

local api = require('api')
local Log = require('log')

local Exp = {}

-- ---------------------------------------------------------------------------
-- result bookkeeping
-- ---------------------------------------------------------------------------

local function newResult(id, title, watch)
  return {
    id = id,
    title = title,
    watch = watch,        -- what the user should be looking at on screen
    verdict = 'UNTESTED',  -- UNTESTED | PASS | FAIL | INCONCLUSIVE
    evidence = {},         -- auto-collected, machine-observed facts
    note = '',             -- free text set by the buttons
  }
end

Exp.results = {
  stat = newResult('E-STAT',
    'Per-NPC SmartGunTimeToLock*ComponentMultiplier',
    'Aim at the modified NPC with a smart gun. PASS = its lock box never fills while a ' ..
    'second, unmodified NPC standing next to it still locks normally.'),
  track = newResult('E-TRACK',
    'Weapon-side SmartGunTrack{Head,Chest}Components',
    'Watch the small lock boxes on a live NPC. PASS = the head/chest boxes vanish the ' ..
    'moment you press the button, with no holster/re-equip.'),
  ignore = newResult('E-IGNORE',
    'TargetingSystem.AddIgnoredLookAtEntity',
    'PASS = the ignored NPC is skipped by smart lock while its neighbours still lock. ' ..
    'Also note whether an ALREADY-HELD lock on it breaks, or only new acquisition stops.'),
  filter = newResult('E-FILTER',
    'TargetFilter_Script.Filter via Register/ProcessLookAtFilter',
    'Nothing to see on screen - this one is read entirely off the CONTROL and LIVE ' ..
    'counters below. Run CONTROL first.'),
  aimassist = newResult('E-AIMASSIST',
    'TargetingSystem.SetAimAssistConfig preset swap',
    'Expected result is NO CHANGE to smart lock (aim assist and smart gun tracking are ' ..
    'separate systems). Confirming that is the point: it closes off a dead lead in 10 min.'),
}

Exp.state = {
  appliedMods = {},   -- every stat modifier this session owns
  ignored = {},       -- idKey -> entityID handed to AddIgnoredLookAtEntity
  filterTicket = nil,
  filterInstance = nil,
  aimOriginal = nil,
  aimApplied = nil,
  observersInstalled = false,
  observerError = nil,
}

Exp.filterCounts = { pre = 0, filter = 0, post = 0 }
Exp.filterControl = { ran = false, fired = false, detail = '' }
Exp.filterLive = { registered = false, fired = false, baseline = 0, detail = '' }

local function addEvidence(res, fmt, ...)
  local text = select('#', ...) > 0 and string.format(fmt, ...) or fmt
  res.evidence[#res.evidence + 1] = text
  if #res.evidence > 12 then table.remove(res.evidence, 1) end
end
Exp.addEvidence = addEvidence

function Exp.setVerdict(res, verdict, note)
  res.verdict = verdict
  res.note = note or res.note
  Log.write('%s -> %s%s', res.id, verdict, note and (' (' .. note .. ')') or '')
end

-- ---------------------------------------------------------------------------
-- E-STAT :: per-NPC time-to-lock inflation
--
-- The decisive experiment. If a modifier on the TARGET's StatsObjectID moves the
-- native lock timer, the faction axis in Enforcement/Faction.reds is buildable.
-- ---------------------------------------------------------------------------

-- kind is a free-text tag so teardown can report what it unwound.
local function trackModifier(kind, label, objId, statName, modTypeName, value, mod)
  Exp.state.appliedMods[#Exp.state.appliedMods + 1] = {
    kind = kind, label = label, objId = objId,
    stat = statName, modType = modTypeName, value = value, mod = mod,
  }
end

local function removeTracked(predicate)
  local removed, failed = 0, 0
  for i = #Exp.state.appliedMods, 1, -1 do
    local entry = Exp.state.appliedMods[i]
    if predicate == nil or predicate(entry) then
      local ok, err = api.removeModifier(entry.objId, entry.mod)
      if ok then
        removed = removed + 1
      else
        failed = failed + 1
        Log.write('RemoveModifier FAILED on %s/%s: %s', entry.label, entry.stat, tostring(err))
      end
      table.remove(Exp.state.appliedMods, i)
    end
  end
  return removed, failed
end
Exp.removeTracked = removeTracked

-- Applies to the NPC's own StatsObjectID (an EntityID; see api.statValue notes).
-- Returns a result table the UI renders directly.
function Exp.statApply(entityID, label, statName, modTypeName, value)
  local res = Exp.results.stat
  if entityID == nil then
    return { ok = false, msg = 'no target selected' }
  end

  local before = api.statValue(entityID, statName)
  local mod, how = api.makeModifier(statName, modTypeName, value)
  if not mod then
    addEvidence(res, 'modifier construction failed: %s', tostring(how))
    return { ok = false, msg = 'could not build modifier: ' .. tostring(how) }
  end

  local ok, err = api.addModifier(entityID, mod)
  if not ok then
    addEvidence(res, 'AddModifier rejected: %s', tostring(err))
    return { ok = false, msg = 'AddModifier failed: ' .. tostring(err) }
  end

  trackModifier('E-STAT', label, entityID, statName, modTypeName, value, mod)
  local after = api.statValue(entityID, statName)

  addEvidence(res, '%s %s %s=%s : %s -> %s',
    label, statName, modTypeName, api.num(value, '%.1f'),
    api.num(before, '%.4f'), api.num(after, '%.4f'))
  Log.write('E-STAT apply %s %s %s %.2f | before=%s after=%s (built via %s)',
    label, statName, modTypeName, value, api.num(before, '%.4f'), api.num(after, '%.4f'), tostring(how))

  local landed = (type(before) == 'number' and type(after) == 'number' and
                  math.abs(after - before) > 0.0001)
  if not landed then
    addEvidence(res, 'STAT DID NOT MOVE - see the base-value hint in the panel')
  end

  return {
    ok = true, before = before, after = after, landed = landed, how = how,
    msg = landed and 'modifier landed' or 'modifier applied but the stat value did not change',
  }
end

function Exp.statClear()
  local removed, failed = removeTracked(function(e) return e.kind == 'E-STAT' end)
  Log.write('E-STAT cleared %d modifier(s), %d failure(s)', removed, failed)
  return removed, failed
end

-- Nuclear option: wipes every modifier on that stat for that object, ours or not.
function Exp.statNuke(entityID, statName)
  local ok, err = api.removeAllModifiers(entityID, statName)
  Log.write('E-STAT RemoveAllModifiers(%s) -> %s', statName, ok and 'ok' or tostring(err))
  return ok, err
end

-- ---------------------------------------------------------------------------
-- E-TRACK :: weapon-side component tracking
--
-- Vanilla base smart weapon ships Chest=3, Leg=2, Mechanical=1, so a Multiplier of 0
-- is the clean way to zero a class. Additive is offered too because a Multiplier is
-- inert against a base of 0 (which is itself a finding worth recording).
-- ---------------------------------------------------------------------------

function Exp.trackSet(statsObjID, objLabel, statName, modTypeName, value)
  local res = Exp.results.track
  if statsObjID == nil then
    return { ok = false, msg = 'no weapon stats object - hold a smart weapon' }
  end

  local before = api.statValue(statsObjID, statName)
  local mod, how = api.makeModifier(statName, modTypeName, value)
  if not mod then
    return { ok = false, msg = 'could not build modifier: ' .. tostring(how) }
  end

  local ok, err = api.addModifier(statsObjID, mod)
  if not ok then
    addEvidence(res, 'AddModifier rejected on %s: %s', objLabel, tostring(err))
    return { ok = false, msg = 'AddModifier failed: ' .. tostring(err) }
  end

  trackModifier('E-TRACK', objLabel, statsObjID, statName, modTypeName, value, mod)
  local after = api.statValue(statsObjID, statName)

  addEvidence(res, '%s [%s] %s=%s : %s -> %s',
    statName, objLabel, modTypeName, api.num(value, '%.1f'),
    api.num(before, '%.3f'), api.num(after, '%.3f'))
  Log.write('E-TRACK %s on %s %s %.2f | before=%s after=%s',
    statName, objLabel, modTypeName, value, api.num(before, '%.3f'), api.num(after, '%.3f'))

  return { ok = true, before = before, after = after, msg = 'applied' }
end

function Exp.trackClear()
  local removed, failed = removeTracked(function(e) return e.kind == 'E-TRACK' end)
  Log.write('E-TRACK cleared %d modifier(s), %d failure(s)', removed, failed)
  return removed, failed
end

-- EnableSmartGunHandlerEvent (orphans.script:61871) queued onto the weapon, exactly as
-- vehicleTransition.script:2424-2433 does it.
function Exp.enableSmartGunHandler(weapon, enable)
  if weapon == nil then return false, 'no weapon' end
  local player = api.player()
  local evt = api.safe(function() return NewObject('EnableSmartGunHandlerEvent') end)
  if evt == nil then
    return false, 'NewObject(EnableSmartGunHandlerEvent) failed'
  end
  local ok, err = api.safe(function()
    evt.owner = player
    evt.enable = enable
    weapon:QueueEvent(evt)
    return true
  end)
  if not ok then return false, tostring(err) end
  Log.write('E-TRACK EnableSmartGunHandlerEvent(enable=%s) queued', tostring(enable))
  return true
end

-- ---------------------------------------------------------------------------
-- E-IGNORE :: targeting-system ignore list
-- orphans.script:22443 / :22445; vanilla precedent deviceBase.script:3827-3837
-- ---------------------------------------------------------------------------

function Exp.ignoreAdd(entityID, label)
  local res = Exp.results.ignore
  local ts, player = api.targeting(), api.player()
  if not ts or not player then return false, 'targeting system or player unavailable' end
  if entityID == nil then return false, 'no target selected' end

  local key = api.idStr(entityID)
  if Exp.state.ignored[key] then return false, 'already ignored' end

  local ok, err = api.safe(function()
    ts:AddIgnoredLookAtEntity(player, entityID)
    return true
  end)
  if not ok then
    addEvidence(res, 'AddIgnoredLookAtEntity threw: %s', tostring(err))
    return false, tostring(err)
  end

  Exp.state.ignored[key] = entityID
  addEvidence(res, 'ignoring %s (%s)', label or key, key)
  Log.write('E-IGNORE added %s', key)
  return true
end

function Exp.ignoreRemove(entityID)
  local ts, player = api.targeting(), api.player()
  if not ts or not player then return false, 'targeting system or player unavailable' end
  local key = api.idStr(entityID)
  local stored = Exp.state.ignored[key] or entityID
  local ok, err = api.safe(function()
    ts:RemoveIgnoredLookAtEntity(player, stored)
    return true
  end)
  Exp.state.ignored[key] = nil
  if not ok then return false, tostring(err) end
  Log.write('E-IGNORE removed %s', key)
  return true
end

function Exp.ignoreClear()
  local n = 0
  for key, eid in pairs(Exp.state.ignored) do
    local ok = Exp.ignoreRemove(eid)
    if ok then n = n + 1 else Exp.state.ignored[key] = nil end
  end
  Exp.state.ignored = {}
  return n
end

function Exp.ignoreCount()
  local n = 0
  for _ in pairs(Exp.state.ignored) do n = n + 1 end
  return n
end

-- ---------------------------------------------------------------------------
-- E-FILTER :: does TargetFilter_Script.Filter() reach script at all?
--
-- targetingSystem.script:13-34 declares TargetFilter_Script with script-side bodies for
-- PreFilter / Filter / PostFilter, so those three are hookable RTTI script functions.
--
-- HARD LIMIT, stated up front: CET's NewProxy builds an IScriptable-derived proxy. It
-- CANNOT declare a subclass of a native class, so Lua cannot supply its own Filter()
-- body. What Lua CAN do is Observe the base class's Filter and count invocations - which
-- is exactly what decides whether the lead is alive. If the CONTROL below fires, the
-- redscript probe in redscript_probe/KSTPFilterProbe.reds is the next step; if it does
-- not fire, the native caller never enters script and the lead is dead for redscript too.
-- ---------------------------------------------------------------------------

function Exp.installObservers()
  if Exp.state.observersInstalled then return true end

  local ok, err = api.safe(function()
    Observe('TargetFilter_Script', 'PreFilter', function()
      Exp.filterCounts.pre = Exp.filterCounts.pre + 1
    end)
    Observe('TargetFilter_Script', 'Filter', function()
      Exp.filterCounts.filter = Exp.filterCounts.filter + 1
    end)
    Observe('TargetFilter_Script', 'PostFilter', function()
      Exp.filterCounts.post = Exp.filterCounts.post + 1
    end)
    return true
  end)

  Exp.state.observersInstalled = (ok == true)
  Exp.state.observerError = ok and nil or tostring(err)
  Log.write('E-FILTER observers %s%s',
    Exp.state.observersInstalled and 'installed' or 'FAILED',
    Exp.state.observerError and (': ' .. Exp.state.observerError) or '')
  return Exp.state.observersInstalled
end

local function newFilterInstance()
  for _, name in ipairs({ 'TargetFilter_Script', 'gameTargetFilter_Script' }) do
    local inst = api.safe(function() return NewObject(name) end)
    if inst ~= nil then return inst, name end
  end
  return nil, nil
end

-- The CONTROL. Calls the native entry point directly. If the observer does not fire here,
-- the hook is wired wrong (or the native side never calls into script) - which is a very
-- different conclusion from "the lead is dead", and the UI must say which.
function Exp.filterRunControl()
  local res = Exp.results.filter
  local ts, player = api.targeting(), api.player()
  if not ts or not player then
    Exp.filterControl = { ran = false, fired = false, detail = 'targeting system or player unavailable' }
    return false
  end
  if not Exp.state.observersInstalled then
    Exp.filterControl = { ran = false, fired = false, detail = 'observers were never installed - see onInit error' }
    return false
  end

  local inst, className = newFilterInstance()
  if inst == nil then
    Exp.filterControl = { ran = false, fired = false,
      detail = 'NewObject(TargetFilter_Script) failed - cannot instantiate a native class from Lua on this CET build' }
    addEvidence(res, 'CONTROL blocked: could not instantiate TargetFilter_Script')
    Log.write('E-FILTER CONTROL blocked: NewObject failed')
    return false
  end

  local before = {
    pre = Exp.filterCounts.pre,
    filter = Exp.filterCounts.filter,
    post = Exp.filterCounts.post,
  }

  local ok, err = api.safe(function()
    ts:ProcessLookAtFilter(player, inst)
    return true
  end)
  if not ok then
    Exp.filterControl = { ran = true, fired = false, detail = 'ProcessLookAtFilter threw: ' .. tostring(err) }
    addEvidence(res, 'CONTROL: ProcessLookAtFilter threw: %s', tostring(err))
    Log.write('E-FILTER CONTROL threw: %s', tostring(err))
    return false
  end

  local dPre = Exp.filterCounts.pre - before.pre
  local dFil = Exp.filterCounts.filter - before.filter
  local dPost = Exp.filterCounts.post - before.post

  local detail
  if dFil > 0 then
    detail = string.format('Filter() fired %d time(s) (pre=%d post=%d) via %s - SCRIPT IS REACHED', dFil, dPre, dPost, className)
  elseif dPre > 0 or dPost > 0 then
    detail = string.format('Filter() did NOT fire but PreFilter=%d PostFilter=%d did. The native side ' ..
      'enters script but had no hit candidates - aim at an NPC and re-run.', dPre, dPost)
  else
    detail = 'no callback fired at all. Either the hook is not attached or ProcessLookAtFilter ' ..
      'never dispatches to script. Treat E-FILTER as INCONCLUSIVE, not FAIL, until the redscript probe agrees.'
  end

  Exp.filterControl = { ran = true, fired = dFil > 0, detail = detail }
  addEvidence(res, 'CONTROL: %s', detail)
  Log.write('E-FILTER CONTROL: %s', detail)
  return dFil > 0
end

function Exp.filterRegisterLive()
  local ts, player = api.targeting(), api.player()
  if not ts or not player then return false, 'targeting system or player unavailable' end
  if Exp.state.filterTicket ~= nil then return false, 'already registered' end

  local inst = newFilterInstance()
  if inst == nil then return false, 'NewObject(TargetFilter_Script) failed' end

  local ticket, err = api.safe(function() return ts:RegisterLookAtFilter(player, inst) end)
  if ticket == nil then
    Exp.filterLive.detail = 'RegisterLookAtFilter failed: ' .. tostring(err)
    return false, Exp.filterLive.detail
  end

  Exp.state.filterInstance = inst
  Exp.state.filterTicket = ticket
  Exp.filterLive.registered = true
  Exp.filterLive.fired = false
  Exp.filterLive.baseline = Exp.filterCounts.filter
  Exp.filterLive.detail = 'registered - now aim at NPCs for ~10 seconds and watch the counter'
  Log.write('E-FILTER live filter registered')
  return true
end

function Exp.filterUnregister()
  if Exp.state.filterTicket == nil then return false, 'nothing registered' end
  local ts, player = api.targeting(), api.player()
  local ok, err = api.safe(function()
    ts:UnregisterLookAtFilter(player, Exp.state.filterTicket)
    return true
  end)
  Exp.state.filterTicket = nil
  Exp.state.filterInstance = nil
  Exp.filterLive.registered = false
  Log.write('E-FILTER live filter unregistered%s', ok and '' or (' (threw: ' .. tostring(err) .. ')'))
  return ok == true, err
end

function Exp.filterPoll()
  if not Exp.filterLive.registered then return end
  if Exp.filterCounts.filter > Exp.filterLive.baseline and not Exp.filterLive.fired then
    Exp.filterLive.fired = true
    Exp.filterLive.detail = string.format('Filter() fired during gameplay (%d calls since registration)',
      Exp.filterCounts.filter - Exp.filterLive.baseline)
    addEvidence(Exp.results.filter, 'LIVE: %s', Exp.filterLive.detail)
    Log.write('E-FILTER LIVE: %s', Exp.filterLive.detail)
  end
end

-- ---------------------------------------------------------------------------
-- E-AIMASSIST :: the 10-minute disproof
--
-- player.script:6036 sets the preset with SetAimAssistConfig(this, configRecord.GetID()).
-- The four presets hang off AimAssistSettings_Record (orphans.script:42094-42110), reached
-- from t"AimAssist.Settings_Default" (playerListeners.script:282).
--
-- Caveat the UI repeats: PlayerPuppet.ApplyAimAssistSettings re-applies the vanilla preset
-- whenever the player's aim-assist state changes (ADS, vehicle, melee...), so the swap can
-- be silently reverted a second later. Re-apply immediately before judging.
-- ---------------------------------------------------------------------------

local presetGetters = {
  Off = function(r) return r:Off() end,
  Light = function(r) return r:Light() end,
  Standard = function(r) return r:Standard() end,
  Heavy = function(r) return r:Heavy() end,
}
Exp.aimPresetNames = { 'Off', 'Light', 'Standard', 'Heavy' }

function Exp.aimCurrent()
  local ts, player = api.targeting(), api.player()
  if not ts or not player then return nil end
  return api.safe(function() return ts:GetAimAssistConfig(player) end)
end

function Exp.aimApply(presetName)
  local res = Exp.results.aimassist
  local ts, player = api.targeting(), api.player()
  if not ts or not player then return false, 'targeting system or player unavailable' end

  local getter = presetGetters[presetName]
  if getter == nil then return false, 'unknown preset ' .. tostring(presetName) end

  local settings = api.safe(function() return TweakDB:GetRecord('AimAssist.Settings_Default') end)
  if settings == nil then
    return false, 'TweakDB:GetRecord("AimAssist.Settings_Default") returned nothing'
  end

  local preset = api.safe(function() return getter(settings) end)
  if preset == nil then return false, 'AimAssistSettings_Record.' .. presetName .. '() returned nothing' end

  local id = api.safe(function() return preset:GetID() end)
  if id == nil then return false, 'preset record has no GetID()' end

  if Exp.state.aimOriginal == nil then
    Exp.state.aimOriginal = Exp.aimCurrent()
  end

  local ok, err = api.safe(function()
    ts:SetAimAssistConfig(player, id)
    return true
  end)
  if not ok then return false, tostring(err) end

  Exp.state.aimApplied = presetName
  local now = Exp.aimCurrent()
  addEvidence(res, 'preset -> %s (%s); readback %s', presetName, api.tdbStr(id), api.tdbStr(now))
  Log.write('E-AIMASSIST applied %s (%s); readback %s', presetName, api.tdbStr(id), api.tdbStr(now))
  return true
end

function Exp.aimRestore()
  local ts, player = api.targeting(), api.player()
  if not ts or not player then return false, 'targeting system or player unavailable' end
  if Exp.state.aimOriginal == nil then return false, 'nothing to restore' end
  local ok, err = api.safe(function()
    ts:SetAimAssistConfig(player, Exp.state.aimOriginal)
    return true
  end)
  if ok then
    Log.write('E-AIMASSIST restored original preset %s', api.tdbStr(Exp.state.aimOriginal))
    Exp.state.aimApplied = nil
  end
  return ok == true, err
end

-- ---------------------------------------------------------------------------
-- teardown
-- ---------------------------------------------------------------------------

function Exp.teardown()
  local removed, failed = removeTracked(nil)
  local unignored = Exp.ignoreClear()
  if Exp.state.filterTicket ~= nil then Exp.filterUnregister() end
  if Exp.state.aimApplied ~= nil then Exp.aimRestore() end
  api.clearClassCache()
  Log.write('TEARDOWN: %d modifier(s) removed (%d failed), %d ignore entr(ies) cleared',
    removed, failed, unignored)
  return removed, failed, unignored
end

-- ---------------------------------------------------------------------------
-- report
-- ---------------------------------------------------------------------------

local order = { 'stat', 'track', 'ignore', 'filter', 'aimassist' }

function Exp.buildReport(extra)
  local out = {}
  local function w(fmt, ...)
    out[#out + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt
  end

  w('=== KSTP LAB RESULTS ===')
  w('game build: 2.31 (assumed - confirm in the launcher)')
  w('CET version: %s', tostring(api.safe(function() return GetVersion() end) or 'unknown'))
  local ok, when = pcall(os.date, '%Y-%m-%d %H:%M:%S')
  w('recorded: %s', ok and tostring(when) or 'unknown')
  w('')

  for _, key in ipairs(order) do
    local r = Exp.results[key]
    w('[%s] %s', r.verdict, r.id)
    w('  %s', r.title)
    if r.note ~= '' then w('  note: %s', r.note) end
    if #r.evidence == 0 then
      w('  evidence: (none recorded)')
    else
      for i = 1, #r.evidence do w('  evidence: %s', r.evidence[i]) end
    end
    w('')
  end

  w('E-FILTER counters: PreFilter=%d Filter=%d PostFilter=%d',
    Exp.filterCounts.pre, Exp.filterCounts.filter, Exp.filterCounts.post)
  w('E-FILTER control : %s', Exp.filterControl.ran and Exp.filterControl.detail or 'not run')
  w('E-FILTER live    : %s', Exp.filterLive.registered and Exp.filterLive.detail or 'not registered')
  w('observers installed: %s%s', tostring(Exp.state.observersInstalled),
    Exp.state.observerError and (' (' .. Exp.state.observerError .. ')') or '')
  w('')

  w('--- gate mapping for Core/Gate.reds ---')
  w('KSTPGate.FactionAxisEnabled  <- E-STAT   = %s', Exp.results.stat.verdict)
  w('KSTPGate.LiveStatReread      <- E-TRACK  = %s', Exp.results.track.verdict)
  w('KSTPGate.IgnoreListWorks     <- E-IGNORE = %s', Exp.results.ignore.verdict)
  w('')

  if extra and #extra > 0 then
    w('--- session notes ---')
    for i = 1, #extra do w('%s', extra[i]) end
    w('')
  end

  w('--- last %d log lines ---', math.min(#Log.lines(), 60))
  local lines = Log.lines()
  local from = math.max(1, #lines - 59)
  for i = from, #lines do w('%s', lines[i]) end

  return out
end

return Exp
