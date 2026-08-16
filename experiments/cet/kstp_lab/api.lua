-- KSTP Lab :: api.lua
--
-- Defensive wrappers over the game API. Nothing in here throws: every call comes back
-- as a value or as (nil, reason), so a missing symbol degrades into a red line in the
-- UI instead of killing the mod.
--
-- Every game symbol used is cited to the decompiled 2.31 dump at
-- C:\tmp\cp2077-research\scripts. If a citation is absent the line is marked UNVERIFIED.
--
-- CET-side conventions used here (CET >= 1.18):
--   Game.Get<X>System()            -- GameInstance statics with the instance auto-filled
--   FromVariant(v) / ToVariant(v)  -- CET 1.18.0 patch notes
--   NewObject('rttiClassName')     -- Scripting.cpp globals["NewObject"]
--   Enum.new('type', 'value')      -- Scripting.cpp globals.new_usertype<Enum>
--   strings implicitly cast to TweakDBID (CET 1.13.0 patch notes)

local api = {}

-- ---------------------------------------------------------------------------
-- error-tolerant plumbing
-- ---------------------------------------------------------------------------

-- Runs fn() and swallows any error. Returns (value) or (nil, message).
function api.safe(fn)
  local ok, res = pcall(fn)
  if ok then return res end
  return nil, tostring(res)
end

-- True when v is a live handle or struct that can be indexed.
local function usable(v)
  return v ~= nil and v ~= false
end

-- ---------------------------------------------------------------------------
-- scalar formatting
-- ---------------------------------------------------------------------------

-- CName -> string. CET exposes .value on CName; Game.NameToString is the older path
-- (HUDitor/init.lua in the reference corpus uses Game.NameToString).
function api.nameStr(cn)
  if cn == nil then return '' end
  if type(cn) == 'string' then return cn end
  local v = api.safe(function() return cn.value end)
  if type(v) == 'string' and v ~= '' then return v end
  v = api.safe(function() return Game.NameToString(cn) end)
  if type(v) == 'string' and v ~= '' then return v end
  return tostring(cn)
end

-- Enum handle -> readable name. CET's Enum usertype stringifies to the value name.
function api.enumStr(e)
  if e == nil then return '?' end
  if type(e) == 'string' then return e end
  local s = api.safe(function() return e.value end)
  if type(s) == 'string' and s ~= '' then return s end
  s = api.safe(function() return tostring(e) end)
  if type(s) == 'string' and s ~= '' then return s end
  return '?'
end

-- Builds a typed enum value for a field assignment or an argument. Falls back to the
-- bare string, which CET's converter also accepts for enum-typed parameters.
function api.enumVal(typeName, valueName)
  local e = api.safe(function() return Enum.new(typeName, valueName) end)
  if usable(e) then return e end
  return valueName
end

-- EntityID -> stable string key. EntityID.ToDebugString exists at orphans.script:11860
-- but is a struct static, which CET does not always surface; .hash is the CET view.
function api.idStr(eid)
  if eid == nil then return 'nil' end
  local h = api.safe(function() return tostring(eid.hash) end)
  if type(h) == 'string' and h ~= '' and h ~= 'nil' then return h end
  h = api.safe(function() return EntityID.ToDebugString(eid) end)
  if type(h) == 'string' and h ~= '' then return h end
  return tostring(eid)
end

function api.tdbStr(id)
  if id == nil then return 'nil' end
  local s = api.safe(function() return tostring(id.value) end)
  if type(s) == 'string' and s ~= '' and s ~= 'nil' then return s end
  s = api.safe(function() return tostring(id.hash) end)
  if type(s) == 'string' and s ~= '' then return 'tdbid#' .. s end
  return tostring(id)
end

function api.num(v, fmt)
  if type(v) ~= 'number' then return '--' end
  return string.format(fmt or '%.2f', v)
end

-- ---------------------------------------------------------------------------
-- systems  (GameInstance statics, orphans.script:11437 GetTargetingSystem,
--           :11549 FindEntityByID; StatsSystem methods at :16943/:16949/:16934)
-- ---------------------------------------------------------------------------

function api.player()
  return api.safe(function() return Game.GetPlayer() end)
end

function api.targeting()
  return api.safe(function() return Game.GetTargetingSystem() end)
end

function api.stats()
  return api.safe(function() return Game.GetStatsSystem() end)
end

function api.transactions()
  return api.safe(function() return Game.GetTransactionSystem() end)
end

function api.blackboardDefs()
  return api.safe(function() return Game.GetAllBlackboardDefs() end)
end

function api.findEntity(eid)
  if eid == nil then return nil end
  return api.safe(function() return Game.FindEntityByID(eid) end)
end

-- ---------------------------------------------------------------------------
-- smart-gun blackboard readout
--
-- blackboardDefinitions.script:1601  UI_ActiveWeaponData.SmartGunParams (Variant)
-- orphans.script:54441               smartGunUIParameters { targets, sight, ... }
-- orphans.script:54420               smartGunUITargetParameters { entityID, isLocked,
--                                    state, distance, accuracy, timeLocking, ... }
-- Vanilla read pattern copied from hud_panzer.script:130-132 / :347.
-- ---------------------------------------------------------------------------

function api.smartGunParams()
  local defs = api.blackboardDefs()
  if not usable(defs) then return nil, 'Game.GetAllBlackboardDefs() unavailable' end

  local bb = api.safe(function()
    return Game.GetBlackboardSystem():Get(defs.UI_ActiveWeaponData)
  end)
  if not usable(bb) then return nil, 'UI_ActiveWeaponData blackboard not resolved' end

  local raw = api.safe(function()
    return bb:GetVariant(defs.UI_ActiveWeaponData.SmartGunParams)
  end)
  if not usable(raw) then
    return nil, 'SmartGunParams is empty - equip a smart weapon and aim (ADS)'
  end

  -- CET may hand back the unwrapped handle or a Variant box depending on build; take
  -- whichever indexes.
  local direct = api.safe(function() return raw.targets end)
  if direct ~= nil then return raw end

  local unwrapped = api.safe(function() return FromVariant(raw) end)
  if not usable(unwrapped) then return nil, 'FromVariant(SmartGunParams) failed' end
  return unwrapped
end

-- Flattens the live lock list into plain Lua tables so the UI never touches a stale
-- native handle.
function api.smartGunTargets()
  local params, err = api.smartGunParams()
  if not params then return nil, err end

  local list = api.safe(function() return params.targets end)
  if type(list) ~= 'table' then return {}, nil, params end

  local out = {}
  for i = 1, #list do
    local t = list[i]
    local eid = api.safe(function() return t.entityID end)
    out[#out + 1] = {
      index = i,
      entityID = eid,
      idKey = api.idStr(eid),
      isLocked = api.safe(function() return t.isLocked end) == true,
      state = api.enumStr(api.safe(function() return t.state end)),
      distance = api.safe(function() return t.distance end),
      accuracy = api.safe(function() return t.accuracy end),
      timeLocking = api.safe(function() return t.timeLocking end),
      timeUnlocking = api.safe(function() return t.timeUnlocking end),
      bone = api.nameStr(api.safe(function() return t.attachedBoneName end)),
    }
  end
  return out, nil, params
end

-- ---------------------------------------------------------------------------
-- classification
--
-- scriptedPuppet.script:1114 GetRecord      -> orphans.script:16278 Affiliation()
-- orphans.script:27846/27848/27852          -> LocalizedName / EnumName / Type
-- gameObject.script:451 static / :465 instance GetAttitudeTowards
-- orphans.script:16600 GetNPCRarity, scriptedPuppet.script:1118 GetNPCType,
--   :1143 IsNetrunnerPuppet, :1394 IsCharacterCivilian, :1425 IsCrowd,
--   :1553 IsPrevention, :1310 IsMaxTac
-- gameObject.script:1319/1343/1315/1359 IsPuppet / IsNPC / IsVehicle / IsDevice
-- ---------------------------------------------------------------------------

local function attitudeOf(obj, player)
  if not usable(obj) or not usable(player) then return nil, false end
  -- Instance overload first (gameObject.script:465).
  local a = api.safe(function() return obj:GetAttitudeTowards(player) end)
  if usable(a) then return api.enumStr(a), true end
  -- Agent-to-agent, which is what the instance overload does internally. Non-puppets
  -- have no agent, so this correctly reports "unknown" rather than a fake Neutral.
  local known = false
  local viaAgent = api.safe(function()
    local ours = player:GetAttitudeAgent()
    local theirs = obj:GetAttitudeAgent()
    if ours == nil or theirs == nil then return nil end
    known = true
    return theirs:GetAttitudeTowards(ours)
  end)
  if usable(viaAgent) then return api.enumStr(viaAgent), known end
  return nil, false
end

function api.classify(obj)
  local c = {
    valid = false,
    name = '',
    isPuppet = false, isNPC = false, isVehicle = false, isDevice = false,
    affiliation = '', affiliationType = '',
    attitude = 'unknown', attitudeKnown = false,
    npcType = '?', rarity = '?',
    netrunner = false, civilian = false, crowd = false, prevention = false,
    maxtac = false,
  }
  if not usable(obj) then return c end
  c.valid = true

  local player = api.player()

  c.name = api.safe(function() return obj:GetDisplayName() end) or ''
  c.isPuppet = api.safe(function() return obj:IsPuppet() end) == true
  c.isNPC = api.safe(function() return obj:IsNPC() end) == true
  c.isVehicle = api.safe(function() return obj:IsVehicle() end) == true
  c.isDevice = api.safe(function() return obj:IsDevice() end) == true

  local att, known = attitudeOf(obj, player)
  if att then c.attitude = att end
  c.attitudeKnown = known

  -- Character_Record is puppet-only; devices and vehicles legitimately have none.
  local rec = api.safe(function() return obj:GetRecord() end)
  if usable(rec) then
    local aff = api.safe(function() return rec:Affiliation() end)
    if usable(aff) then
      c.affiliation = api.nameStr(api.safe(function() return aff:EnumName() end))
      c.affiliationType = api.enumStr(api.safe(function() return aff:Type() end))
    end
  end

  c.npcType = api.enumStr(api.safe(function() return obj:GetNPCType() end))
  c.rarity = api.enumStr(api.safe(function() return obj:GetNPCRarity() end))
  c.netrunner = api.safe(function() return obj:IsNetrunnerPuppet() end) == true
  c.civilian = api.safe(function() return obj:IsCharacterCivilian() end) == true
  c.crowd = api.safe(function() return obj:IsCrowd() end) == true
  c.prevention = api.safe(function() return obj:IsPrevention() end) == true
  c.maxtac = api.safe(function() return obj:IsMaxTac() end) == true

  return c
end

-- Per-entity cache. The immutable axes are resolved once; attitude is refreshed on the
-- ttl because it is group-relational and changes mid-fight.
local classCache = {}
local classCacheSize = 0
local CLASS_CACHE_CAP = 256

function api.classifyCached(eid, key, now, ttl)
  key = key or api.idStr(eid)
  local hit = classCache[key]
  if hit and (now - hit.at) < (ttl or 0.5) then return hit.data end

  local obj = api.findEntity(eid)
  local data = api.classify(obj)
  if hit == nil then
    classCacheSize = classCacheSize + 1
    -- A long session in a busy district can see thousands of entity ids; drop the whole
    -- table rather than grow without bound.
    if classCacheSize > CLASS_CACHE_CAP then
      classCache = {}
      classCacheSize = 1
    end
  end
  classCache[key] = { at = now, data = data }
  return data
end

function api.clearClassCache()
  classCache = {}
  classCacheSize = 0
end

-- ---------------------------------------------------------------------------
-- targeting queries
-- orphans.script:22401 GetLookAtObject, :22417 GetTrackedTargetObject
-- ---------------------------------------------------------------------------

function api.lookAtObject()
  local ts, player = api.targeting(), api.player()
  if not usable(ts) or not usable(player) then return nil, 'targeting system or player unavailable' end
  local o = api.safe(function() return ts:GetLookAtObject(player, false, false) end)
  if usable(o) then return o end
  o = api.safe(function() return ts:GetLookAtObject(player) end)
  if usable(o) then return o end
  return nil, 'no look-at object (nothing under the crosshair)'
end

function api.trackedTargetObject()
  local ts, player = api.targeting(), api.player()
  if not usable(ts) or not usable(player) then return nil end
  return api.safe(function() return ts:GetTrackedTargetObject(player) end)
end

function api.entityIDOf(obj)
  if not usable(obj) then return nil end
  return api.safe(function() return obj:GetEntityID() end)
end

-- ---------------------------------------------------------------------------
-- stats
--
-- orphans.script:16934 GetStatValue(StatsObjectID, gamedataStatType) -> Float
-- orphans.script:16943 AddModifier / :16949 RemoveModifier / :16955 RemoveAllModifiers
-- orphans.script:16903 gameConstantStatModifierData { statType, modifierType, value }
-- rpgManager.script:1387 CreateStatModifier builds exactly that object, so it is built
-- directly and avoid guessing RPGManager's RTTI name from Lua.
--
-- StatsObjectID: an EntityID is accepted where StatsObjectID is expected (the vanilla
-- Cast<StatsObjectID>(x.GetEntityID()) at ripperdoc.script:517-518 is the same coercion),
-- and item stats live on ItemData.GetStatsObjectID (orphans.script:17018, used at
-- effector.script:37).
-- ---------------------------------------------------------------------------

function api.statValue(statsObjID, statName)
  local sys = api.stats()
  if not usable(sys) or statsObjID == nil then return nil, 'stats system or object id unavailable' end
  local v, err = api.safe(function() return sys:GetStatValue(statsObjID, api.enumVal('gamedataStatType', statName)) end)
  if type(v) == 'number' then return v end
  -- Bare-string enum path, in case Enum.new is unavailable on this CET build.
  v, err = api.safe(function() return sys:GetStatValue(statsObjID, statName) end)
  if type(v) == 'number' then return v end
  return nil, err or 'GetStatValue returned no value'
end

-- Returns (modifier, howItWasBuilt) or (nil, reason).
function api.makeModifier(statName, modTypeName, value)
  local m = api.safe(function()
    local o = NewObject('gameConstantStatModifierData')
    o.statType = api.enumVal('gamedataStatType', statName)
    o.modifierType = api.enumVal('gameStatModifierType', modTypeName)
    o.value = value
    return o
  end)
  if usable(m) then return m, 'NewObject(gameConstantStatModifierData)' end

  -- Fallback: the vanilla factory. RTTI name differs between builds, so try both.
  for _, singleton in ipairs({ 'RPGManager', 'gameRPGManager' }) do
    local mgr = api.safe(function() return GetSingleton(singleton) end)
    if usable(mgr) then
      local r = api.safe(function() return mgr:CreateStatModifier(statName, modTypeName, value) end)
      if usable(r) then return r, 'GetSingleton("' .. singleton .. '"):CreateStatModifier' end
    end
  end
  return nil, 'could not construct a gameConstantStatModifierData'
end

function api.addModifier(statsObjID, modifier)
  local sys = api.stats()
  if not usable(sys) then return false, 'stats system unavailable' end
  if statsObjID == nil or not usable(modifier) then return false, 'bad object id or modifier' end
  local ok, err = api.safe(function() return sys:AddModifier(statsObjID, modifier) end)
  if err then return false, err end
  return ok ~= false, nil
end

function api.removeModifier(statsObjID, modifier)
  local sys = api.stats()
  if not usable(sys) then return false, 'stats system unavailable' end
  if statsObjID == nil or not usable(modifier) then return false, 'bad object id or modifier' end
  local ok, err = api.safe(function() return sys:RemoveModifier(statsObjID, modifier) end)
  if err then return false, err end
  return ok ~= false, nil
end

function api.removeAllModifiers(statsObjID, statName)
  local sys = api.stats()
  if not usable(sys) then return false, 'stats system unavailable' end
  local ok, err = api.safe(function()
    return sys:RemoveAllModifiers(statsObjID, api.enumVal('gamedataStatType', statName), true)
  end)
  if err then return false, err end
  return ok ~= false, nil
end

-- ---------------------------------------------------------------------------
-- held weapon
--
-- orphans.script:18131 TransactionSystem.GetItemInSlot(obj, slotID)
-- vehicleTransition.script:2427 uses t"AttachmentSlots.WeaponRight" for exactly this.
-- item.script:12 GetItemData(); orphans.script:17018 ItemData.GetStatsObjectID()
-- ---------------------------------------------------------------------------

function api.heldWeapon()
  local ts, player = api.transactions(), api.player()
  if not usable(ts) or not usable(player) then return nil, 'transaction system or player unavailable' end

  local w = api.safe(function() return ts:GetItemInSlot(player, 'AttachmentSlots.WeaponRight') end)
  if usable(w) then return w end
  w = api.safe(function() return ts:GetItemInSlot(player, TweakDBID.new('AttachmentSlots.WeaponRight')) end)
  if usable(w) then return w end
  return nil, 'no item in AttachmentSlots.WeaponRight'
end

-- Both plausible stats objects for a weapon. Vanilla is inconsistent: the SmartWeapon
-- effector path uses ItemData (effector.script:37) while crosshair code reads the entity
-- (crosshairController_Smart_Rifle.script:134). Show both, let the experiment decide.
function api.weaponStatTargets(weapon)
  local out = { itemData = nil, entity = nil }
  if not usable(weapon) then return out end
  local itemData = api.safe(function() return weapon:GetItemData() end)
  if usable(itemData) then
    out.itemData = api.safe(function() return itemData:GetStatsObjectID() end)
  end
  out.entity = api.safe(function() return weapon:GetEntityID() end)
  return out
end

function api.weaponLabel(weapon)
  if not usable(weapon) then return '(none)' end
  local n = api.safe(function() return weapon:GetDisplayName() end)
  if type(n) == 'string' and n ~= '' then return n end
  return 'weapon#' .. api.idStr(api.safe(function() return weapon:GetEntityID() end))
end

-- Is the held weapon a smart gun? WeaponItem_Record.Evolution().Type() ==
-- gamedataWeaponEvolution.Smart, the same test vehicleTransition.script:2429 uses.
function api.heldWeaponIsSmart(weapon)
  if not usable(weapon) then return false, 'no weapon' end
  local evo = api.safe(function() return weapon:GetWeaponRecord():Evolution():Type() end)
  if evo == nil then return false, 'weapon record / evolution unreadable' end
  return api.enumStr(evo) == 'Smart', api.enumStr(evo)
end

return api
