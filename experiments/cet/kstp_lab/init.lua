-- KSTP Lab -- CET experiment rig for the Kiroshi Smart Targeting Protocol
--
-- Drop this folder into:
--   Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\kstp_lab\
--
-- Open the CET overlay (default: `) and find the "KSTP Lab" window.
-- Read README.md before running the experiments; the order matters.
--
-- Everything this rig touches is unwound on shutdown and by the PANIC button.

local api = require('api')
local Log = require('log')
local Exp = require('experiments')

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

local lab = {
  overlayOpen = false,

  -- Pinned HUD readout: a second, click-through window that stays up with the overlay
  -- closed, because a weapon cannot be aimed while the overlay holds input focus.
  --
  -- Off by default. It draws over gameplay every frame and is a diagnostic surface, not
  -- something to leave running. Turn it on from section 1 of the lab window, or bind the
  -- "KSTP: toggle pinned readout" hotkey under CET > Bindings.
  pinReadout = false,

  -- live readout
  refreshInterval = 0.10,
  sinceRefresh = 0.0,
  targets = {},
  targetsError = nil,
  classTTL = 0.75,
  clock = 0.0,

  -- target selection
  pinnedID = nil,
  pinnedLabel = '',

  -- E-STAT controls
  statClass = 'Chest',
  statModType = 'Multiplier',
  statValue = 1000.0,
  statLast = nil,

  -- E-TRACK controls
  trackObject = 'itemData',   -- 'itemData' | 'entity'
  trackModType = 'Multiplier',
  trackValue = 0.0,
  trackLast = nil,
  cycleStage = nil,

  -- misc
  deferred = {},
  sessionNotes = {},
  lastMessage = '',
  lastMessageBad = false,
}

local TIME_TO_LOCK_STATS = {
  Head       = 'SmartGunTimeToLockHeadComponentMultiplier',
  Chest      = 'SmartGunTimeToLockChestComponentMultiplier',
  Leg        = 'SmartGunTimeToLockLegComponentMultiplier',
  WeakSpot   = 'SmartGunTimeToLockWeakSpotComponentMultiplier',
  Mechanical = 'SmartGunTimeToLockMechanicalComponentMultiplier',
  Breach     = 'SmartGunTimeToLockBreachComponentMultiplier',
  Vehicle    = 'SmartGunTimeToLockVehicleComponentMultiplier',
}
local TRACK_STATS = {
  Head       = 'SmartGunTrackHeadComponents',
  Chest      = 'SmartGunTrackChestComponents',
  Leg        = 'SmartGunTrackLegComponents',
  WeakSpot   = 'SmartGunTrackWeakSpotComponents',
  Mechanical = 'SmartGunTrackMechanicalComponents',
  Breach     = 'SmartGunTrackBreachComponents',
  Vehicle    = 'SmartGunTrackVehicleComponents',
}
local CLASS_ORDER = { 'Head', 'Chest', 'Leg', 'WeakSpot', 'Mechanical', 'Breach', 'Vehicle' }
local MOD_TYPES = { 'Multiplier', 'Additive', 'AdditiveMultiplier' }

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function say(msg, bad)
  lab.lastMessage = msg or ''
  lab.lastMessageBad = bad == true
  if msg and msg ~= '' then Log.write(msg) end
end

-- CET passes onUpdate a float. Builds disagree on seconds vs milliseconds, so normalise
-- rather than trust it: no real frame is longer than a second.
local function normDelta(dt)
  if type(dt) ~= 'number' or dt <= 0 then return 0.016 end
  if dt > 1.0 then return dt / 1000.0 end
  return dt
end

local function after(seconds, fn)
  lab.deferred[#lab.deferred + 1] = { t = seconds, fn = fn }
end

local function runDeferred(dt)
  for i = #lab.deferred, 1, -1 do
    local d = lab.deferred[i]
    d.t = d.t - dt
    if d.t <= 0 then
      table.remove(lab.deferred, i)
      local ok, err = pcall(d.fn)
      if not ok then Log.write('deferred task failed: %s', tostring(err)) end
    end
  end
end

local function objLabel(obj)
  if obj == nil then return '(none)' end
  local n = api.safe(function() return obj:GetDisplayName() end)
  if type(n) == 'string' and n ~= '' then return n end
  return 'entity#' .. api.idStr(api.entityIDOf(obj))
end

-- The entity the experiments act on: the pin if set, otherwise whatever is under the
-- crosshair right now.
local function currentTarget()
  if lab.pinnedID ~= nil then
    return lab.pinnedID, lab.pinnedLabel, true
  end
  local obj = api.lookAtObject()
  if obj == nil then return nil, nil, false end
  return api.entityIDOf(obj), objLabel(obj), false
end

local function pinLookAt()
  local obj, err = api.lookAtObject()
  if obj == nil then
    say('pin failed: ' .. tostring(err), true)
    return false
  end
  lab.pinnedID = api.entityIDOf(obj)
  lab.pinnedLabel = objLabel(obj)
  say(string.format('pinned %s (%s)', lab.pinnedLabel, api.idStr(lab.pinnedID)))
  return true
end

-- ---------------------------------------------------------------------------
-- live readout
-- ---------------------------------------------------------------------------

local function refreshTargets()
  local list, err = api.smartGunTargets()
  if list == nil then
    lab.targets = {}
    lab.targetsError = err
    return
  end
  lab.targetsError = nil
  for i = 1, #list do
    list[i].cls = api.classifyCached(list[i].entityID, list[i].idKey, lab.clock, lab.classTTL)
  end
  lab.targets = list
end

-- ---------------------------------------------------------------------------
-- ImGui plumbing
-- ---------------------------------------------------------------------------

local COL = {
  pass = { 0.35, 0.90, 0.45, 1.0 },
  fail = { 0.95, 0.35, 0.35, 1.0 },
  inconclusive = { 0.95, 0.75, 0.25, 1.0 },
  untested = { 0.62, 0.62, 0.62, 1.0 },
  hostile = { 0.95, 0.42, 0.35, 1.0 },
  neutral = { 0.85, 0.85, 0.85, 1.0 },
  friendly = { 0.45, 0.80, 0.95, 1.0 },
  locked = { 1.00, 0.30, 0.30, 1.0 },
  locking = { 0.98, 0.78, 0.22, 1.0 },
  idle = { 0.70, 0.70, 0.70, 1.0 },
  dim = { 0.58, 0.58, 0.58, 1.0 },
  good = { 0.45, 0.90, 0.55, 1.0 },
  bad = { 0.95, 0.40, 0.40, 1.0 },
}

local function col(c, text)
  ImGui.TextColored(c[1], c[2], c[3], c[4], text)
end

local function verdictColour(v)
  if v == 'PASS' then return COL.pass end
  if v == 'FAIL' then return COL.fail end
  if v == 'INCONCLUSIVE' then return COL.inconclusive end
  return COL.untested
end

local function cond(name, fallback)
  local t = ImGuiCond
  if type(t) == 'table' and t[name] ~= nil then return t[name] end
  return fallback
end

local function winFlag(name, fallback)
  local t = ImGuiWindowFlags
  if type(t) == 'table' and t[name] ~= nil then return t[name] end
  return fallback
end

-- Verdict recorder shared by every experiment panel.
local function drawVerdictRow(res, suffix)
  col(verdictColour(res.verdict), 'verdict: ' .. res.verdict)
  ImGui.SameLine()
  if ImGui.Button('PASS##' .. suffix) then Exp.setVerdict(res, 'PASS') end
  ImGui.SameLine()
  if ImGui.Button('FAIL##' .. suffix) then Exp.setVerdict(res, 'FAIL') end
  ImGui.SameLine()
  if ImGui.Button('INCONCL##' .. suffix) then Exp.setVerdict(res, 'INCONCLUSIVE') end
  ImGui.SameLine()
  if ImGui.Button('reset##' .. suffix) then Exp.setVerdict(res, 'UNTESTED') end
end

local function drawWatchLine(res)
  col(COL.dim, 'LOOK AT:')
  ImGui.SameLine()
  ImGui.TextWrapped(res.watch)
end

local function drawEvidence(res)
  if #res.evidence == 0 then return end
  for i = 1, #res.evidence do
    col(COL.dim, '  . ' .. res.evidence[i])
  end
end

-- Row of exclusive buttons; returns the newly chosen value or nil.
local function choiceRow(label, options, current, suffix)
  ImGui.Text(label)
  local chosen = nil
  for i = 1, #options do
    local opt = options[i]
    ImGui.SameLine()
    if opt == current then
      col(COL.good, '[' .. opt .. ']')
    else
      if ImGui.Button(opt .. '##' .. suffix) then chosen = opt end
    end
  end
  return chosen
end

-- ---------------------------------------------------------------------------
-- panels
-- ---------------------------------------------------------------------------

local function drawStatusPanel()
  local player = api.player()
  local ts = api.targeting()
  local stats = api.stats()
  local weapon = api.heldWeapon()
  local isSmart, evo = api.heldWeaponIsSmart(weapon)

  local function flag(ok, name)
    ImGui.SameLine()
    col(ok and COL.good or COL.bad, (ok and '+' or 'x') .. name)
  end

  ImGui.Text('systems:')
  flag(player ~= nil, 'player')
  flag(ts ~= nil, 'targeting')
  flag(stats ~= nil, 'stats')
  flag(api.transactions() ~= nil, 'transactions')
  flag(api.blackboardDefs() ~= nil, 'blackboard')

  ImGui.Text('held weapon: ' .. api.weaponLabel(weapon))
  if weapon ~= nil then
    ImGui.SameLine()
    if isSmart then
      col(COL.good, '[SMART]')
    else
      col(COL.inconclusive, '[' .. tostring(evo) .. ' - not smart]')
    end
  end

  if lab.lastMessage ~= '' then
    col(lab.lastMessageBad and COL.bad or COL.dim, lab.lastMessage)
  end
end

local function drawReadoutRows(compact)
  if lab.targetsError then
    col(COL.inconclusive, lab.targetsError)
    return
  end
  if #lab.targets == 0 then
    col(COL.dim, 'blackboard reachable, target list empty')
    return
  end

  for i = 1, #lab.targets do
    local t = lab.targets[i]
    local c = t.cls or {}

    local stateCol = COL.idle
    if t.isLocked or t.state == 'Locked' then stateCol = COL.locked
    elseif t.state == 'Locking' then stateCol = COL.locking end

    col(stateCol, string.format('%d. %-9s %s  d=%sm acc=%s%s',
      i, t.state, t.isLocked and '[LOCKED]' or '        ',
      api.num(t.distance, '%.1f'), api.num(t.accuracy, '%.2f'),
      (t.bone ~= '' and ('  bone=' .. t.bone) or '')))

    if not compact then
      col(COL.dim, '   id=' .. t.idKey .. '  ' .. (c.name or ''))
    end

    local attCol = COL.neutral
    if c.attitude == 'AIA_Hostile' then attCol = COL.hostile
    elseif c.attitude == 'AIA_Friendly' then attCol = COL.friendly end

    if c.valid then
      col(attCol, string.format('   AFF=%s  ATT=%s%s  RAR=%s  TYPE=%s%s%s%s%s',
        (c.affiliation ~= '' and c.affiliation or '-'),
        c.attitude,
        c.attitudeKnown and '' or '(no agent)',
        c.rarity, c.npcType,
        c.netrunner and '  NETRUNNER' or '',
        c.civilian and '  civilian' or '',
        c.crowd and '  crowd' or '',
        c.maxtac and '  MAXTAC' or ''))
    else
      col(COL.dim, '   entity not resolvable from EntityID (despawned or not a GameObject)')
    end
  end
end

local function drawReadoutPanel()
  ImGui.Text(string.format('tracked targets: %d', #lab.targets))
  ImGui.SameLine()
  if ImGui.Button('flush class cache') then
    api.clearClassCache()
    say('classification cache flushed')
  end

  lab.refreshInterval = ImGui.SliderFloat('refresh (s)##readout', lab.refreshInterval, 0.0, 1.0, '%.2f')
  if type(lab.refreshInterval) ~= 'number' then lab.refreshInterval = 0.10 end

  ImGui.Separator()
  drawReadoutRows(false)
  ImGui.Separator()
  col(COL.dim, 'Empty list is normal until you equip a smart weapon and aim. The blackboard is')
  col(COL.dim, 'only written while the smart-gun handler is active (ADS on most smart guns).')
end

local function drawTargetPanel()
  local eid, label, pinned = currentTarget()

  if pinned then
    col(COL.good, 'PINNED: ' .. tostring(lab.pinnedLabel) .. '  id=' .. api.idStr(lab.pinnedID))
    if ImGui.Button('unpin##target') then
      lab.pinnedID, lab.pinnedLabel = nil, ''
      say('unpinned')
    end
  else
    if eid ~= nil then
      col(COL.neutral, 'LOOK-AT: ' .. tostring(label) .. '  id=' .. api.idStr(eid))
    else
      col(COL.dim, 'LOOK-AT: nothing under the crosshair')
    end
    if ImGui.Button('pin current look-at##target') then pinLookAt() end
  end

  ImGui.SameLine()
  if ImGui.Button('pin from lock list[1]##target') then
    if #lab.targets > 0 then
      lab.pinnedID = lab.targets[1].entityID
      lab.pinnedLabel = (lab.targets[1].cls and lab.targets[1].cls.name) or lab.targets[1].idKey
      say('pinned first tracked target: ' .. lab.pinnedLabel)
    else
      say('lock list is empty', true)
    end
  end

  col(COL.dim, 'You cannot aim while the CET overlay has focus. Bind the "pin look-at target"')
  col(COL.dim, 'hotkey in CET > Bindings, aim at an NPC, press it, then open the overlay.')
end

local function drawStatPanel()
  local res = Exp.results.stat
  drawWatchLine(res)
  ImGui.Separator()

  local eid, label = currentTarget()

  local chosen = choiceRow('class:', CLASS_ORDER, lab.statClass, 'estatclass')
  if chosen then lab.statClass = chosen end

  chosen = choiceRow('modifier:', MOD_TYPES, lab.statModType, 'estatmod')
  if chosen then lab.statModType = chosen end

  local statName = TIME_TO_LOCK_STATS[lab.statClass]

  lab.statValue = ImGui.SliderFloat('value##estat', lab.statValue, 0.0, 10000.0, '%.0f')
  if type(lab.statValue) ~= 'number' then lab.statValue = 1000.0 end
  ImGui.Text('quick:')
  for _, v in ipairs({ 10, 100, 1000, 10000 }) do
    ImGui.SameLine()
    if ImGui.Button(tostring(v) .. '##estatq') then lab.statValue = v + 0.0 end
  end

  ImGui.Separator()
  ImGui.Text('stat: ' .. statName)
  if eid ~= nil then
    local live = api.statValue(eid, statName)
    ImGui.Text(string.format('target %s  current value = %s', tostring(label), api.num(live, '%.4f')))
    if type(live) == 'number' and live == 0.0 and lab.statModType == 'Multiplier' then
      col(COL.inconclusive,
        'base is 0.0 -- a Multiplier cannot move it. Switch to Additive, or this stat is not')
      col(COL.inconclusive,
        'defined on NPCs at all (which is itself the E-STAT answer: FAIL, weapon-side only).')
    end
  else
    col(COL.dim, 'no target')
  end

  if ImGui.Button('APPLY to target##estat') then
    local id, lbl = currentTarget()
    if id == nil then
      say('E-STAT: no target selected', true)
    else
      lab.statLast = Exp.statApply(id, lbl or api.idStr(id), statName, lab.statModType, lab.statValue)
      say('E-STAT: ' .. tostring(lab.statLast.msg), not lab.statLast.ok)
    end
  end
  ImGui.SameLine()
  if ImGui.Button('CLEAR ours##estat') then
    local n = Exp.statClear()
    say(string.format('E-STAT: removed %d modifier(s)', n))
  end
  ImGui.SameLine()
  if ImGui.Button('RemoveAllModifiers##estat') then
    local id = currentTarget()
    if id then
      local ok, err = Exp.statNuke(id, statName)
      say('E-STAT nuke: ' .. (ok and 'ok' or tostring(err)), not ok)
    end
  end

  if lab.statLast then
    col(lab.statLast.landed and COL.good or COL.inconclusive,
      string.format('last apply: %s -> %s  (%s)',
        api.num(lab.statLast.before, '%.4f'), api.num(lab.statLast.after, '%.4f'),
        tostring(lab.statLast.how)))
  end

  ImGui.Separator()
  col(COL.dim, 'PROTOCOL: modify ONE of two NPCs standing together. Holster, re-draw, aim at')
  col(COL.dim, 'each in turn. PASS only if the modified one refuses to complete a lock while')
  col(COL.dim, 'the other locks normally. A stat value that moves but changes nothing on')
  col(COL.dim, 'screen is FAIL, not PASS -- the native handler may read weapon-side only.')
  drawEvidence(res)
  drawVerdictRow(res, 'estat')
end

local function weaponStatsObject()
  local weapon = api.heldWeapon()
  if weapon == nil then return nil, nil, nil end
  local targets = api.weaponStatTargets(weapon)
  local chosen = (lab.trackObject == 'entity') and targets.entity or targets.itemData
  return chosen, weapon, targets
end

local function drawTrackPanel()
  local res = Exp.results.track
  drawWatchLine(res)
  ImGui.Separator()

  local statsObj, weapon, targets = weaponStatsObject()
  if weapon == nil then
    col(COL.bad, 'no weapon in AttachmentSlots.WeaponRight')
    drawVerdictRow(res, 'etrack')
    return
  end

  local chosen = choiceRow('stats object:', { 'itemData', 'entity' }, lab.trackObject, 'etrackobj')
  if chosen then lab.trackObject = chosen end
  col(COL.dim, 'itemData = weapon:GetItemData():GetStatsObjectID()  (what the vanilla Kiroshi')
  col(COL.dim, 'cyberware effector targets).  entity = weapon:GetEntityID().  If one moves the')
  col(COL.dim, 'lock boxes and the other does not, that answers which one the handler reads.')

  ImGui.Separator()
  ImGui.Text('current track stat values:')
  for _, cls in ipairs({ 'Head', 'Chest', 'Leg', 'WeakSpot', 'Mechanical' }) do
    local s = TRACK_STATS[cls]
    local viaItem = targets.itemData and api.statValue(targets.itemData, s) or nil
    local viaEnt = targets.entity and api.statValue(targets.entity, s) or nil
    col(COL.dim, string.format('  %-11s itemData=%s   entity=%s',
      cls, api.num(viaItem, '%.2f'), api.num(viaEnt, '%.2f')))
  end

  ImGui.Separator()
  chosen = choiceRow('modifier:', MOD_TYPES, lab.trackModType, 'etrackmod')
  if chosen then lab.trackModType = chosen end
  lab.trackValue = ImGui.SliderFloat('value##etrack', lab.trackValue, -100.0, 10.0, '%.1f')
  if type(lab.trackValue) ~= 'number' then lab.trackValue = 0.0 end
  ImGui.SameLine()
  if ImGui.Button('0##etrackq') then lab.trackValue = 0.0 end
  ImGui.SameLine()
  if ImGui.Button('-100##etrackq') then lab.trackValue = -100.0 end

  local function applyTrack(cls)
    local obj = statsObj
    if obj == nil then
      say('E-TRACK: chosen stats object is nil', true)
      return
    end
    lab.trackLast = Exp.trackSet(obj, lab.trackObject, TRACK_STATS[cls], lab.trackModType, lab.trackValue)
    say('E-TRACK ' .. cls .. ': ' .. tostring(lab.trackLast.msg), not lab.trackLast.ok)
  end

  if ImGui.Button('HEAD -> value##etrack') then applyTrack('Head') end
  ImGui.SameLine()
  if ImGui.Button('CHEST -> value##etrack') then applyTrack('Chest') end
  ImGui.SameLine()
  if ImGui.Button('LEG -> value##etrack') then applyTrack('Leg') end
  ImGui.SameLine()
  if ImGui.Button('RESTORE ALL##etrack') then
    local n = Exp.trackClear()
    say(string.format('E-TRACK: removed %d modifier(s)', n))
  end

  ImGui.Separator()
  ImGui.Text('re-latch test:')
  ImGui.SameLine()
  if ImGui.Button('cycle smart-gun handler##etrack') then
    local w = api.heldWeapon()
    local ok, err = Exp.enableSmartGunHandler(w, false)
    if not ok then
      say('E-TRACK cycle: ' .. tostring(err), true)
    else
      lab.cycleStage = 'off'
      say('E-TRACK: handler disabled, re-enabling in 0.6s')
      after(0.6, function()
        local ok2, err2 = Exp.enableSmartGunHandler(api.heldWeapon(), true)
        lab.cycleStage = ok2 and 'on' or 'failed'
        say('E-TRACK cycle: ' .. (ok2 and 'handler re-enabled' or tostring(err2)), not ok2)
        Exp.addEvidence(Exp.results.track, 'handler cycled off/on: %s', ok2 and 'ok' or tostring(err2))
      end)
    end
  end
  if lab.cycleStage then
    col(COL.dim, 'cycle stage: ' .. lab.cycleStage)
  end

  ImGui.Separator()
  col(COL.dim, 'PROTOCOL: get into a fight, hold ADS on an NPC so the small component boxes are')
  col(COL.dim, 'visible, then press HEAD or CHEST. PASS = those boxes disappear immediately with')
  col(COL.dim, 'no holster. If they only disappear after the handler cycle, record PASS and note')
  col(COL.dim, '"needs re-latch" -- that decides KSTPGate.LiveStatReread.')
  drawEvidence(res)
  drawVerdictRow(res, 'etrack')
end

local function drawIgnorePanel()
  local res = Exp.results.ignore
  drawWatchLine(res)
  ImGui.Separator()

  local eid, label = currentTarget()
  ImGui.Text(string.format('ignore list holds %d entit(ies)', Exp.ignoreCount()))

  if ImGui.Button('ADD current target##eignore') then
    local id, lbl = currentTarget()
    local ok, err = Exp.ignoreAdd(id, lbl)
    say('E-IGNORE add: ' .. (ok and tostring(lbl) or tostring(err)), not ok)
  end
  ImGui.SameLine()
  if ImGui.Button('REMOVE current target##eignore') then
    local id = currentTarget()
    local ok, err = Exp.ignoreRemove(id)
    say('E-IGNORE remove: ' .. (ok and 'ok' or tostring(err)), not ok)
  end
  ImGui.SameLine()
  if ImGui.Button('CLEAR ALL##eignore') then
    local n = Exp.ignoreClear()
    say(string.format('E-IGNORE: cleared %d', n))
  end

  if eid ~= nil then
    local key = api.idStr(eid)
    local isIgnored = Exp.state.ignored[key] ~= nil
    col(isIgnored and COL.good or COL.dim,
      string.format('current target %s is %s', tostring(label), isIgnored and 'IGNORED' or 'not ignored'))
  end

  ImGui.Separator()
  col(COL.dim, 'PROTOCOL, two parts, both matter:')
  col(COL.dim, '  (a) ADD while NOT locked onto it -> can the smart gun still acquire it?')
  col(COL.dim, '  (b) ADD while ALREADY locked onto it -> does the existing lock break, or hold?')
  col(COL.dim, 'Record the answer to (b) in the note field of the report; the ignore list is')
  col(COL.dim, 'documented for look-at, and smart lock is a separate native pipeline.')
  drawEvidence(res)
  drawVerdictRow(res, 'eignore')
end

local function drawFilterPanel()
  local res = Exp.results.filter
  drawWatchLine(res)
  ImGui.Separator()

  col(COL.inconclusive, 'LIMITATION, stated honestly:')
  ImGui.TextWrapped(
    'CET NewProxy builds an IScriptable-derived proxy. It cannot declare a subclass of the ' ..
    'native class TargetFilter_Script, so Lua cannot supply its own Filter() body. This rig ' ..
    'therefore Observes the base class Filter/PreFilter/PostFilter and counts invocations. ' ..
    'That is enough to decide the lead. If CONTROL fires, build the redscript probe in ' ..
    'redscript_probe/KSTPFilterProbe.reds next; if CONTROL does not fire, script is never ' ..
    'entered and no redscript subclass will help either.')

  ImGui.Separator()
  col(Exp.state.observersInstalled and COL.good or COL.bad,
    'observers installed: ' .. tostring(Exp.state.observersInstalled))
  if Exp.state.observerError then
    col(COL.bad, '  ' .. Exp.state.observerError)
  end
  ImGui.Text(string.format('counters   PreFilter=%d  Filter=%d  PostFilter=%d',
    Exp.filterCounts.pre, Exp.filterCounts.filter, Exp.filterCounts.post))

  ImGui.Separator()
  ImGui.Text('STEP 1 - CONTROL (run this first):')
  if ImGui.Button('call ProcessLookAtFilter directly##efilter') then
    Exp.filterRunControl()
    say('E-FILTER control: ' .. Exp.filterControl.detail, not Exp.filterControl.fired)
  end
  if Exp.filterControl.ran then
    col(Exp.filterControl.fired and COL.pass or COL.fail,
      'CONTROL: ' .. (Exp.filterControl.fired and 'CALLBACK FIRED' or 'CALLBACK DID NOT FIRE'))
    ImGui.TextWrapped('  ' .. Exp.filterControl.detail)
  else
    col(COL.untested, 'CONTROL: not run')
  end

  ImGui.Separator()
  ImGui.Text('STEP 2 - LIVE registration:')
  if not Exp.filterLive.registered then
    if ImGui.Button('RegisterLookAtFilter##efilter') then
      local ok, err = Exp.filterRegisterLive()
      say('E-FILTER register: ' .. (ok and 'ok' or tostring(err)), not ok)
    end
  else
    if ImGui.Button('UnregisterLookAtFilter##efilter') then
      Exp.filterUnregister()
      say('E-FILTER unregistered')
    end
  end
  if Exp.filterLive.registered or Exp.filterLive.fired then
    col(Exp.filterLive.fired and COL.pass or COL.untested,
      'LIVE: ' .. (Exp.filterLive.fired and 'CALLBACK FIRED' or 'no callback yet'))
    if Exp.filterLive.detail ~= '' then ImGui.TextWrapped('  ' .. Exp.filterLive.detail) end
  else
    col(COL.untested, 'LIVE: not registered')
  end

  ImGui.Separator()
  col(COL.dim, 'Reading the two lines together:')
  col(COL.dim, '  CONTROL fired + LIVE fired      -> PASS, script-side filtering is real')
  col(COL.dim, '  CONTROL fired + LIVE silent     -> registration path is the problem, INCONCLUSIVE')
  col(COL.dim, '  CONTROL silent                  -> INCONCLUSIVE until the redscript probe agrees;')
  col(COL.dim, '                                     a silent control means the hook proves nothing')
  drawEvidence(res)
  drawVerdictRow(res, 'efilter')
end

local function drawAimAssistPanel()
  local res = Exp.results.aimassist
  drawWatchLine(res)
  ImGui.Separator()

  local current = Exp.aimCurrent()
  ImGui.Text('current AimAssistConfigPreset: ' .. api.tdbStr(current))
  if Exp.state.aimOriginal ~= nil then
    col(COL.dim, 'saved original: ' .. api.tdbStr(Exp.state.aimOriginal))
  end

  ImGui.Text('apply:')
  for _, name in ipairs(Exp.aimPresetNames) do
    ImGui.SameLine()
    if ImGui.Button(name .. '##eaim') then
      local ok, err = Exp.aimApply(name)
      say('E-AIMASSIST ' .. name .. ': ' .. (ok and 'applied' or tostring(err)), not ok)
    end
  end

  if ImGui.Button('RESTORE original##eaim') then
    local ok, err = Exp.aimRestore()
    say('E-AIMASSIST restore: ' .. (ok and 'ok' or tostring(err)), not ok)
  end

  ImGui.Separator()
  col(COL.dim, 'CAVEAT: PlayerPuppet.ApplyAimAssistSettings (player.script:5997) re-applies the')
  col(COL.dim, 'vanilla preset whenever the aim-assist state changes -- entering ADS, mounting a')
  col(COL.dim, 'vehicle, drawing a melee weapon. Apply the preset, then judge within a second or')
  col(COL.dim, 'two without changing state, and re-check the readback line above.')
  col(COL.dim, 'EXPECTED: no change to smart lock. Recording that as FAIL is the useful outcome --')
  col(COL.dim, 'it closes the lead so nobody spends a week on it.')
  drawEvidence(res)
  drawVerdictRow(res, 'eaim')
end

local function drawReportPanel()
  if ImGui.Button('WRITE REPORT##report') then
    local body = Exp.buildReport(lab.sessionNotes)
    local ok = Log.writeReport(body)
    say(ok and ('report written to mods/kstp_lab/' .. Log.reportPath) or 'report write FAILED', not ok)
  end
  ImGui.SameLine()
  if ImGui.Button('clear log##report') then Log.clear() end
  ImGui.SameLine()
  if ImGui.Button('PANIC: restore everything##report') then
    local removed, failed, unignored = Exp.teardown()
    say(string.format('teardown: %d modifiers removed (%d failed), %d ignores cleared',
      removed, failed, unignored))
  end

  col(COL.dim, 'Report path: bin/x64/plugins/cyber_engine_tweaks/mods/kstp_lab/' .. Log.reportPath)
  if Log.fileError then col(COL.bad, 'file error: ' .. Log.fileError) end

  ImGui.Separator()
  ImGui.Text('outstanding mutations:')
  col(#Exp.state.appliedMods > 0 and COL.inconclusive or COL.dim,
    string.format('  %d stat modifier(s), %d ignored entit(ies), filter %s, aim preset %s',
      #Exp.state.appliedMods, Exp.ignoreCount(),
      Exp.state.filterTicket and 'REGISTERED' or 'clear',
      Exp.state.aimApplied or 'vanilla'))

  ImGui.Separator()
  ImGui.Text('log:')
  if ImGui.BeginChild('kstp_log_child', 0, 180, true) then
    local lines = Log.lines()
    for i = 1, #lines do
      ImGui.TextWrapped(lines[i])
    end
  end
  ImGui.EndChild()
end

-- ---------------------------------------------------------------------------
-- windows
-- ---------------------------------------------------------------------------

local function drawMainWindow()
  ImGui.SetNextWindowSize(620, 780, cond('FirstUseEver', 4))
  ImGui.SetNextWindowPos(60, 60, cond('FirstUseEver', 4))

  -- Single-argument Begin on purpose: with a close button the window can be dismissed
  -- with no way back, and the overlay already gates visibility.
  local visible = ImGui.Begin('KSTP Lab -- Kiroshi Smart Targeting Protocol')

  if visible then
    drawStatusPanel()
    ImGui.Separator()

    local changed
    lab.pinReadout, changed = ImGui.Checkbox('pinned HUD readout (visible with overlay closed)', lab.pinReadout)
    if changed then end

    ImGui.Separator()
    if ImGui.CollapsingHeader('1. LIVE READOUT  (smart-gun blackboard)') then drawReadoutPanel() end
    if ImGui.CollapsingHeader('   TARGET SELECTION') then drawTargetPanel() end
    if ImGui.CollapsingHeader('2. E-STAT  -- per-NPC time-to-lock  [DECISIVE]') then drawStatPanel() end
    if ImGui.CollapsingHeader('3. E-TRACK -- weapon-side component tracking') then drawTrackPanel() end
    if ImGui.CollapsingHeader('4. E-IGNORE -- targeting ignore list') then drawIgnorePanel() end
    if ImGui.CollapsingHeader('5. E-FILTER -- script-side target filter') then drawFilterPanel() end
    if ImGui.CollapsingHeader('6. E-AIMASSIST -- preset swap (expected null result)') then drawAimAssistPanel() end
    if ImGui.CollapsingHeader('7. REPORT / LOG / TEARDOWN') then drawReportPanel() end
  end

  ImGui.End()
end

local function drawPinnedReadout()
  local flags = winFlag('NoTitleBar', 1)
    + winFlag('AlwaysAutoResize', 64)
    + winFlag('NoFocusOnAppearing', 4096)
  if not lab.overlayOpen then
    -- Click-through while the overlay is closed so the window never eats aim input.
    -- UNVERIFIED: 786944 is the ImGui 1.8x composite value for NoInputs, used only if
    -- this CET build does not expose the ImGuiWindowFlags table.
    flags = flags + winFlag('NoInputs', 786944)
  end

  ImGui.SetNextWindowPos(20, 20, cond('FirstUseEver', 4))
  pcall(function() ImGui.SetNextWindowBgAlpha(0.55) end)

  local a, b = ImGui.Begin('KSTP readout##pinned', true, flags)
  local visible = (b == nil) and a or b
  if visible then
    col(COL.dim, string.format('KSTP LAB  targets=%d  mods=%d  ignored=%d',
      #lab.targets, #Exp.state.appliedMods, Exp.ignoreCount()))
    if lab.pinnedID ~= nil then
      col(COL.good, 'PIN ' .. tostring(lab.pinnedLabel))
    end
    drawReadoutRows(true)
  end
  ImGui.End()
end

-- ---------------------------------------------------------------------------
-- icon probe
--
-- An item's icon is a foreign key to a gamedataUIIcon_Record, and the atlas part names it
-- points at live inside a base-game .inkatlas. Nothing outside the archives lists them, so
-- reading them back off a vanilla frontal-cortex implant at runtime is the only way to name
-- one without unpacking. The last entry is ours, and doubles as a check that the display
-- name registered in UI/Localization.reds resolved.
--
-- One shot at startup. Delete this block once the icon is settled.
-- ---------------------------------------------------------------------------

local ICON_PROBE = {
  'Items.AdvancedVisualCortexSupportCommon',
  'Items.IconicAdvancedSubdermalCoProcessorLegendary',
  'Items.IconicCamilloRamManagerLegendary',
  'Items.MemoryBooster',
  'Items.KSTPKiroshiIFFCoprocessorRare',
}

-- Flats worth reading back. Everything here is a question that cannot be answered from
-- disk: the values live in the compiled TweakDB, where resource paths are hashes and
-- array-typed flats need a real parser.
local FLAT_PROBE = {
  -- Component budget bounds. KSTP adds Additive 2 per unlocked class over a vanilla base
  -- of 0. If max is 1 the budget is really a flag and the 2 is clamped; if it is higher,
  -- the value is a count and the totals below decide how much lock capacity KSTP adds.
  'BaseStats.SmartGunTrackHeadComponents.min',
  'BaseStats.SmartGunTrackHeadComponents.max',
  'BaseStats.SmartGunTrackChestComponents.max',
  'BaseStats.SmartGunTrackWeakSpotComponents.max',
  -- The separate multi-entity axis. This is the one the Intelligence perk Targeting Prism
  -- drives, and the one KSTP must stay out of.
  'BaseStats.SmartGunTrackMultipleEntitiesInADS.min',
  'BaseStats.SmartGunTrackMultipleEntitiesInADS.max',
  -- Which numeric two-column rows a cyberware card is permitted to draw.
  'UIMaps.Cyberware.secondaryStats',
  -- What a vanilla frontal-cortex implant puts in the shard slot. Needed before KSTP can
  -- name one: a dangling foreign key passes TweakXL silently.
  'Items.AdvancedVisualCortexSupportCommon.slotPartListPreset',
  'Items.AdvancedMechatronicCoreCommon.slotPartListPreset',
  'Items.AdvancedVisualCortexSupportCommon.statModifiers',
  'Items.AdvancedVisualCortexSupportCommon.OnEquip',
  -- Attunement numbers. The item-side AttunementHelper modifier only supplies the figure the
  -- card prints; the real bonus lives in the attunement package. The wiki documents the
  -- relationship for IntelligenceAllDamage (real multiplier 0.0005, helper 0.05) so reading
  -- both lets the ratio be confirmed rather than assumed for the smart-weapon variant.
  -- These _inline names are read here only; nothing in the shipped yaml references them,
  -- because inline names are regenerated per patch.
  'Attunements.IntelligenceAllDamage_inline0.value',
  'Attunements.IntelligenceAllDamage_inline0.statType',
  'Attunements.IntelligenceSmartWeaponDamage_inline0.value',
  'Attunements.IntelligenceSmartWeaponDamage_inline0.statType',
  'Attunements.IntelligenceSmartWeaponDamage_inline0.refStat',
  'Attunements.IntelligenceSmartWeaponDamage_inline1.value',
  'Attunements.IntelligenceSmartWeaponDamage_inline1.statType',
  -- Whatever vanilla item already carries the smart-weapon attunement: its own
  -- AttunementHelper modifier is the reference value KSTP should match.
  'Items.AdvancedSmartLinkCommon.statModifiers',
  'Items.AdvancedSmartLinkCommon.OnEquip',
}

-- Does a plain English scalar survive the native LocalizedDescription() accessor, or does
-- it resolve as a localization key and come back empty? This is the open question behind
-- the blank effect list. KSTP's package UIData carries a bare scalar; a vanilla one
-- carries a real LocKey. Printing both bracketed makes an empty string unmistakable.
local UIDATA_PROBE = {
  'KSTP.PkgTargetingProtocol_UI',
  'Attunements.IntelligenceAllDamage',
  'Attunements.IntelligenceSmartWeaponDamage',
}

local function probeIcons()
  Log.write('--- card probe ---')

  for _, id in ipairs(ICON_PROBE) do
    local rec = api.safe(function() return TweakDB:GetRecord(id) end)
    if not rec then
      Log.write('  %-52s NO RECORD', id)
    else
      -- iconPath is the field the inventory resolver actually reads
      -- (inventoryItemsManager.script:128-142). The inline icon record is not on that path,
      -- so it is reported only to show it stays empty on vanilla records.
      local path  = api.safe(function() return tostring(rec:IconPath()) end)
      local icon  = api.safe(function() return rec:Icon() end)
      local part  = icon and api.safe(function() return api.nameStr(icon:AtlasPartName()) end)
      local shown = api.safe(function() return GetLocalizedItemNameByCName(rec:DisplayName()) end)
      Log.write('  %-52s name="%s" iconPath=%s inlinePart=%s',
        id, tostring(shown or ''), tostring(path or 'nil'), tostring(part or 'nil'))
    end
  end

  Log.write('  -- flats --')
  for _, flat in ipairs(FLAT_PROBE) do
    local v = api.safe(function() return TweakDB:GetFlat(flat) end)
    local shown
    if type(v) == 'table' then
      local parts = {}
      for _, e in ipairs(v) do parts[#parts + 1] = tostring(e) end
      shown = '[' .. table.concat(parts, ', ') .. ']'
    else
      shown = tostring(v)
    end
    Log.write('  %-58s = %s', flat, shown)
  end

  Log.write('  -- UIData localizedDescription (empty brackets means the scalar died) --')
  for _, id in ipairs(UIDATA_PROBE) do
    local rec = api.safe(function() return TweakDB:GetRecord(id) end)
    if not rec then
      Log.write('  %-52s NO RECORD', id)
    else
      local d = api.safe(function() return rec:LocalizedDescription() end)
      local n = api.safe(function() return rec:LocalizedName() end)
      Log.write('  %-52s name=[%s] desc=[%s]', id, tostring(n or ''), tostring(d or ''))
    end
  end

  Log.write('--- card probe end ---')
  Log.write('  (component budget deferred until a weapon is drawn)')
end

-- The live component budget on the equipped weapon. This is the number the balance decision
-- turns on: the project's notes claim vanilla ships Chest 3 / Leg 2 / Mechanical 1 and 0 for
-- the other four, and that has never been read back from the game.
--
-- Split out of probeIcons because onInit fires at load, long before the player can have a
-- weapon in hand, so running it there can only ever report an empty slot. Polled instead,
-- and logged once on the first success.
local budgetDone = false
local budgetNextCheck = 0

local function probeBudget()
  local wep = api.heldWeapon()
  if not wep then return false end

  -- Read both stats objects. The effector applies to ItemData (effector.script:37) while
  -- crosshair code reads the entity, and vanilla is inconsistent between the two.
  local t = api.weaponStatTargets(wep)
  Log.write('--- component budget ---')
  Log.write('    weapon: %s', api.weaponLabel(wep))
  for _, s in ipairs({ 'Head', 'Chest', 'Leg', 'Mechanical', 'WeakSpot', 'Breach', 'Vehicle' }) do
    local stat = 'SmartGunTrack' .. s .. 'Components'
    local vi = api.statValue(t.itemData, stat)
    local ve = api.statValue(t.entity, stat)
    Log.write('    %-40s itemData=%s entity=%s', stat, tostring(vi or 'nil'), tostring(ve or 'nil'))
  end
  -- The multi-entity axis, for contrast. It is a boolean (max 1) and belongs to the
  -- Intelligence perk Targeting Prism. KSTP must leave it at its vanilla value.
  local mi = api.statValue(t.itemData, 'SmartGunTrackMultipleEntitiesInADS')
  local me = api.statValue(t.entity, 'SmartGunTrackMultipleEntitiesInADS')
  Log.write('    %-40s itemData=%s entity=%s',
    'SmartGunTrackMultipleEntitiesInADS', tostring(mi or 'nil'), tostring(me or 'nil'))
  Log.write('--- component budget end ---')
  return true
end

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------

registerForEvent('onInit', function()
  Log.write('--- KSTP Lab session start ---')
  Log.write('CET version: %s', tostring(api.safe(function() return GetVersion() end) or 'unknown'))
  probeIcons()
  Exp.installObservers()
  say('KSTP Lab ready. Open section 1 and equip a smart weapon.')
end)

registerForEvent('onUpdate', function(dt)
  local d = normDelta(dt)
  lab.clock = lab.clock + d
  Log.tick(d)
  runDeferred(d)

  -- Poll for the component budget until a weapon is in hand, then log it once. Two seconds
  -- apart so a session spent without a smart weapon costs one cheap slot lookup per tick
  -- rather than a stats read.
  if not budgetDone and lab.clock >= budgetNextCheck then
    budgetNextCheck = lab.clock + 2.0
    local ok, res = pcall(probeBudget)
    if ok and res then
      budgetDone = true
      say('Component budget captured. See the log.')
    end
  end

  lab.sinceRefresh = lab.sinceRefresh + d
  if lab.sinceRefresh >= lab.refreshInterval then
    lab.sinceRefresh = 0.0
    local ok, err = pcall(refreshTargets)
    if not ok then
      lab.targets = {}
      lab.targetsError = 'readout error: ' .. tostring(err)
    end
    Exp.filterPoll()
  end
end)

registerForEvent('onOverlayOpen', function() lab.overlayOpen = true end)
registerForEvent('onOverlayClose', function() lab.overlayOpen = false end)

registerForEvent('onDraw', function()
  if lab.pinReadout then
    pcall(drawPinnedReadout)
  end
  if lab.overlayOpen then
    pcall(drawMainWindow)
  end
end)

registerForEvent('onShutdown', function()
  Exp.teardown()
  Log.write('--- KSTP Lab session end ---')
end)

-- Hotkeys are declared at file root, outside any event handler, and are bound by the
-- user in CET > Bindings. They exist because the overlay steals aim input: every action
-- you need mid-combat has to be reachable with the overlay closed.

registerHotkey('kstp_pin_target', 'KSTP: pin look-at target', function()
  pinLookAt()
end)

registerHotkey('kstp_toggle_readout', 'KSTP: toggle pinned readout', function()
  lab.pinReadout = not lab.pinReadout
end)

registerHotkey('kstp_estat_apply', 'KSTP: E-STAT apply to pinned target', function()
  local id, lbl = currentTarget()
  if id == nil then
    say('E-STAT hotkey: no target', true)
    return
  end
  lab.statLast = Exp.statApply(id, lbl or api.idStr(id),
    TIME_TO_LOCK_STATS[lab.statClass], lab.statModType, lab.statValue)
  say('E-STAT: ' .. tostring(lab.statLast.msg), not lab.statLast.ok)
end)

registerHotkey('kstp_estat_clear', 'KSTP: E-STAT clear all', function()
  local n = Exp.statClear()
  say(string.format('E-STAT: removed %d modifier(s)', n))
end)

registerHotkey('kstp_track_zero', 'KSTP: E-TRACK zero head+chest', function()
  local obj = weaponStatsObject()
  if obj == nil then
    say('E-TRACK hotkey: no weapon stats object', true)
    return
  end
  Exp.trackSet(obj, lab.trackObject, TRACK_STATS.Head, 'Multiplier', 0.0)
  Exp.trackSet(obj, lab.trackObject, TRACK_STATS.Chest, 'Multiplier', 0.0)
  say('E-TRACK: head + chest zeroed on ' .. lab.trackObject)
end)

registerHotkey('kstp_track_restore', 'KSTP: E-TRACK restore', function()
  local n = Exp.trackClear()
  say(string.format('E-TRACK: removed %d modifier(s)', n))
end)

registerHotkey('kstp_panic', 'KSTP: PANIC restore everything', function()
  local removed, failed, unignored = Exp.teardown()
  say(string.format('teardown: %d removed (%d failed), %d ignores cleared', removed, failed, unignored))
end)

return lab
