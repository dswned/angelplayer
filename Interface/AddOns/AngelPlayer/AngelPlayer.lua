DEBUG = 1

local queue = {}

function queue.queue()
  return { first = 0, last = -1 }
end

function queue.push(q, val)
  local last = q.last + 1
  q.last = last
  q[last] = val
end

function queue.pop(q)
  local first = q.first
  local val = q[first]
  q[first] = nil
  q.first = first + 1
  return val
end

function queue.empty(q)
  return q.last - q.first < 0
end

local ntu_meta = {
  __index = function(t, k) if k > 0 then return rawget(t, k + 2) end local v = rawget(t, 2 - k) if v == 'You' then v = 'player' end return v end;
  __newindex = function(t, k, v) rawset(t, k + 2, (v == 'your' or v == 'Your' or v == 'you') and 'You' or rawget(t, v) or v) end; }
local party = {}
local ntu
local broadcast_q = queue.queue()
local party_index, leader_index
local update_auras
local t
local prefix, prefix_event

local tooltip, main, broadcast, combat, main_str, event_str

local COLOR_COMBAT = 'ff7fff7f'

local function list_auras()
  local auras = party['player']['auras']
  local ret = ''
  for key, val in auras do
    if val['rank'] then
      ret = ret .. string.format("%s||%d||", key, val['rank'])
    else
      ret = ret .. string.format("%s||", key)
    end
  end
  return ' auras = ' .. ret
end

local function list_spells()
  local spells = party['player']['spells']
  local ret = ''
  for key, val in spells do
    if val['rank'] then
      ret = ret .. string.format("%s||%d||", key, val['rank'])
    else
      ret = ret .. string.format("%s||", key)
    end
  end
  return ' spells = ' .. ret
end

local function list_stats()
  local player = party['player']
  local text = string.format("%d,%d,%d,%d,%d,%d,%d",
    player['str'], player['agi'], player['sta'], player['int'], player['spi'],
    player['defense'], player['armor'])
  return ' stats = ' .. text
end

local function list_talents()
  return ' talents = ' .. party['player']['talents']
end

local function party_status()
  local power_types = { [0] = 'mana', 'rage', 'focus', 'energy' }
  local str = ''
  for unit in party do
    if unit then
      if not party[unit]['class'] then
        party[unit]['class'] = UnitClass(unit)
        party[unit]['health'] = UnitHealth(unit)
        party[unit]['health_max'] = UnitHealthMax(unit)
        party[unit]['power_type'] = UnitPowerType(unit)
        party[unit]['power'] = UnitMana(unit)
        party[unit]['power_max'] = UnitManaMax(unit)
      end
      str = str .. string.format('%-9s %5d (%d) || %s %5d (%d)\n', unit, party[unit]['health'], party[unit]['health_max'], power_types[party[unit]['power_type']], party[unit]['power'], party[unit]['power_max'])
    end
  end
  str = strsub(str, 0, -2)
  main_str:SetText(str)
end

function debug(level, msg)
  if level >= DEBUG then return end
  if level ~= 0 then
    msg = '|cff7f7f7f' .. string.gsub(msg, '|r', '|cff7f7f7f') .. '|r'
  end
  DEFAULT_CHAT_FRAME:AddMessage(msg)
end

local function format_msg(t, prefix, ...)
  local out = string.format("||%.3f||%s||", t, prefix)
  for i = 1, arg.n do
    if not arg[i] then break end
    out = out .. arg[i] .. '||'
  end
  return out
end

local function format_chat(t, prefix, color, ...)
  local out = ''
  if t then out = string.format("[%.3f]", t) end
  if prefix then
    if color then
      out = out .. '|c' .. color .. '[' .. prefix .. ']|r'
    else
      out = out .. '[' .. prefix .. ']'
    end
  end
  for i = 1, arg.n do
    if not arg[i] or arg[i] == '' then break end
    out = out .. '[' .. arg[i] .. ']'
  end
  return out
end

local broadcast_register_events = {
  'SPELLCAST_START',
  'SPELLCAST_STOP',
  -- gcd, shoot, procs
  'SPELL_UPDATE_COOLDOWN',
  'SPELLCAST_DELAYED',
  'SPELLCAST_INTERRUPTED',
  'SPELLCAST_FAILED',
  'SPELL_FAILED_INTERRUPTED',
  'SPELL_FAILED_INTERRUPTED_COMBAT',
  'SPELL_FAILED_LINE_OF_SIGHT',
  'SPELL_FAILED_OUT_OF_RANGE',
  'SPELL_FAILED_SPELL_IN_PROGRESS',
  'SPELLCAST_CHANNEL_START',
  'SPELLCAST_CHANNEL_STOP',
  'SPELLCAST_CHANNEL_UPDATE',
  'START_AUTOREPEAT_SPELL',
  'STOP_AUTOREPEAT_SPELL',
  'PLAYER_REGEN_DISABLED',
  'PLAYER_REGEN_ENABLED',
  -- You fail to cast (.+): No target.
  -- You fail to cast (.+): Your weapon hand is empty.
  'CHAT_MSG_SPELL_FAILED_LOCALPLAYER',
}

local combat_register_events = {
  'CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS',
  'CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE',
  'CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE',
  'CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS',
  'CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE',
  -- You reflect (\d+) (.+) damage to (.+).
  'CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF',
  -- (.+) reflects (\d+) (.+) damage to (.+).
  'CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS',
  -- (.+) is afflicted by (.+).
  -- (.+) suffers (\d+) (.+) damage from (.+)'s (.+).
  'CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE',
  -- (.+) suffers (\d+) (.+) damage from (?:(your)|(.+)'s) (.+).
  'CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE',
  -- (.+) begins to cast (.+).
  -- (.+)'s (.+) (?:hits|crits) (you|.+) for (\d+) (.+) damage.
  -- Your (.+) crits (.+) for (\d+).
  'CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE',
  -- (.+) is afflicted by (.+).
  -- (.+) suffers (\d+) (.+) damage from your (.+).
  'CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE',
  -- (.+) hits (you|.+) for (\d+).
  'CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS',
  -- (?:(your)|(.+)'s) (.+) (?:hits|crits) (.+) for (\d+) damage.
  -- (.+) performs (.+) on (.+).
  'CHAT_MSG_SPELL_SELF_DAMAGE',
  'CHAT_MSG_SPELL_PARTY_DAMAGE',
  'CHAT_MSG_SPELL_PET_DAMAGE',
  'CHAT_MSG_COMBAT_SELF_HITS',
  'CHAT_MSG_COMBAT_PARTY_HITS',
  'CHAT_MSG_COMBAT_PET_HITS',
  -- (?:(Your)|(.+)'s) (.+) (?:heals|critically heals) (you|.+) for (\d+).
  'CHAT_MSG_SPELL_SELF_BUFF',
  -- You gain (.+).
  -- You gain (.+) health from (.+).
  -- You gain (.+) health from (.+)'s (.+).
  'CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS',
  -- (.+) begins to cast (.+).
  'CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF',
  -- (.+) gains (.+).
  -- (.+) gains (.+) health from (.+)'s (.+).
  'CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS',
  'CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS',
  'CHAT_MSG_SPELL_PARTY_BUFF',
  'UNIT_HEALTH',
  'UNIT_MAXHEALTH',
  'UNIT_DISPLAYPOWER',
  'UNIT_MANA',
  'UNIT_MAXMANA',
  'CHAT_MSG_COMBAT_FRIENDLY_DEATH',
  'CHAT_MSG_COMBAT_HOSTILE_DEATH',
  -- (.+)'s (.+) is removed.
  -- Your (.+) is removed.
  'CHAT_MSG_SPELL_BREAK_AURA',
  -- (.+) fades from (.+).
  'CHAT_MSG_SPELL_AURA_GONE_SELF',
  'CHAT_MSG_SPELL_AURA_GONE_PARTY',
  'CHAT_MSG_SPELL_AURA_GONE_OTHER',
  'CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF',
  'CHAT_MSG_SPELL_PERIODIC_CREATURE_BUFFS',
  'CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE',
  'CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES',
  'CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES',
  -- You attack. (.+) parries.
  -- Your (.+) was dodged.
  'CHAT_MSG_COMBAT_SELF_MISSES',
  -- (.+) attacks. (.+) parries.
  'CHAT_MSG_COMBAT_PARTY_MISSES',
  'CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES',
}

main = CreateFrame('FRAME', nil, UIParent)
tooltip = CreateFrame('GAMETOOLTIP', 'tooltip', nil, 'GameTooltipTemplate')
tooltip:SetOwner(UIParent, 'ANCHOR_NONE')

broadcast = CreateFrame('FRAME', nil, UIParent)
combat = CreateFrame('FRAME', nil, UIParent)

main:SetBackdrop({
  bgFile = 'Interface\\AddOns\\AngelPlayer\\Backdrop',
  edgeFile = '',
  tile = 0, tileSize = 16, edgeSize = 16,
  insets = { left = 0, right = 0, top = 0, bottom = 0 }})
main:SetBackdropColor(1.0, 1.0, 1.0, 0.5)

main:RegisterEvent('PLAYER_LOGIN')
main:RegisterEvent('CHAT_MSG_ADDON')
main:RegisterEvent('PARTY_MEMBERS_CHANGED')
main:RegisterEvent('PARTY_LEADER_CHANGED')
main:RegisterEvent('UNIT_CONNECTION')
main:RegisterEvent('PLAYER_TARGET_CHANGED')
main:RegisterEvent('UNIT_TARGET')
main:RegisterEvent('UNIT_AURA')

local title = CreateFrame('BUTTON', nil, main)
title:EnableMouse(true)
title:SetScript('OnMouseDown', function() main:StartMoving() end)
title:SetScript('OnMouseUp', function() main:StopMovingOrSizing() end)
title:SetHeight(16)
title:SetWidth(160)
title:SetPoint('BOTTOMRIGHT', main, 0, -16)

main:SetPoint('RIGHT', UIParent, 'RIGHT', 0, 0)
main:SetClampedToScreen(true)
main:SetMovable(true)
main:SetWidth(500)
main:SetHeight(200)

main_str = main:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
main_str:SetTextColor(0, 0, 0)
main_str:SetShadowOffset(0, 0)
main_str:SetShadowColor(0, 0, 0, 0)
main_str:SetPoint('LEFT', 0, 0)
main_str:SetPoint('RIGHT', 0, 0)
main_str:SetJustifyH('LEFT')
main_str:SetJustifyV('TOP')
main_str:SetFont('Interface\\AddOns\\AngelPlayer\\10.ttf', 10)
main_str:SetPoint('TOP', 0, 0)
main_str:SetHeight(40)

event_str = main:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
event_str:SetTextColor(0, 0, 0)
event_str:SetShadowOffset(0, 0)
event_str:SetShadowColor(0, 0, 0, 0)
event_str:SetPoint('LEFT', 0, 0)
event_str:SetPoint('RIGHT', 0, 0)
event_str:SetJustifyH('LEFT')
event_str:SetJustifyV('TOP')
event_str:SetFont('Interface\\AddOns\\AngelPlayer\\10.ttf', 10)
event_str:SetPoint('TOP', main_str, 'BOTTOM', 0, 2)
event_str:SetHeight(120)

local event_rows = {}
local ci = 10
function push_event_message(msg)
    if ci == 0 then ci = 10 end
    event_rows[ci] = msg
    local str = ''
    for i = 0, 9 do
      local j = ci + i
      if j > 10 then j = j - 10 end
      str = str .. (event_rows[j] or '') .. '\n'
    end
    event_str:SetText(str)
    ci = ci - 1
end

local spelldb = {}

spelldb['Lesser Heal'] = {
  ['heal'] = { 51, 78, 146 },
  ['mana'] = { 30, 45, 75 },
  ['cast'] = { 1.5, 2.0, 2.5 },
  ['level'] = { 1, 4, 10 } }
spelldb['Renew'] = {
  ['hot'] = { 45, 100, 175, 245, 315, 400, 510 },
  ['mana'] = { 30, 65, 105, 140, 170, 205, 250 },
  ['cast'] = 0,
  ['level'] = { 8, 14, 20, 26, 32, 38, 44 },
  ['text'] = {
    'Healing 9 damage every 3 seconds.',
    'Healing 20 damage every 3 seconds.',
    'Healing 35 damage every 3 seconds.',
    'Healing 49 damage every 3 seconds.',
    'Healing 63 damage every 3 seconds.',
    'Healing 80 damage every 3 seconds.',
    'Healing 102 damage every 3 seconds.',
    'Healing 130 damage every 3 seconds.',
    'Healing 162 damage every 3 seconds.',
    'Healing 194 damage every 3 seconds.',
  }
}
spelldb['Heal'] = {
  ['heal'] = { 318, 460, 604, 758 },
  ['mana'] = { 155, 205, 255, 305 },
  ['cast'] = 3.0,
  ['level'] = { 16, 22, 28, 34 } }
spelldb['Greater Heal'] = {
  ['heal'] = { 956 },
  ['mana'] = { 370 },
  ['cast'] = 3.0,
  ['level'] = { 40 } }
spelldb['Flash Heal'] = {
  ['heal'] = { 215, 286, 360, 439, 567 },
  ['mana'] = { 125, 155, 185, 215, 265 },
  ['cast'] = 1.5,
  ['level'] = { 20, 26, 32, 38, 44 } }
spelldb['Resurrection'] = {
  ['mana'] = { 82 },
  ['cast'] = 10.0,
  ['level'] = { 10 } }
spelldb['Dispel Magic'] = {
  ['mana'] = -1,
  ['cast'] = 0,
  ['level'] = { 18, 36 } }
spelldb['Power Word: Fortitude'] = {
  ['mana'] = { 60, 155, 400, 745 },
  ['cast'] = 0,
  ['level'] = { 1, 12, 24, 36 },
  ['text'] = {
    'Increases Stamina by 3.',
    'Increases Stamina by 8.',
    'Increases Stamina by 20.',
    'Increases Stamina by 32.',
    'Increases Stamina by 43.',
    'Increases Stamina by 54.',
  }
}
spelldb['Shadow Word: Pain'] = {
  ['dot'] = { 30, 66, 132, 234, 366, 510 },
  ['mana'] = { 25, 50, 95, 155, 230, 305 },
  ['cast'] = 0,
  ['level'] = { 4, 10, 18, 26, 34, 42 },
  ['text'] = {
    '5 Shadow damage every 3 seconds.',
    '11 Shadow damage every 3 seconds.',
    '22 Shadow damage every 3 seconds.',
    '39 Shadow damage every 3 seconds.',
    '61 Shadow damage every 3 seconds.',
    '85 Shadow damage every 3 seconds.',
    '112 Shadow damage every 3 seconds.',
    '142 Shadow damage every 3 seconds.',
  }
}
spelldb['Mind Flay'] = {
  ['dot'] = { 75, 126, 186, 261 },
  ['mana'] = { 45, 70, 100, 135 },
  ['channeled'] = 3,
  ['level'] = { 20, 28, 36, 44 } }
spelldb['Mark of the Wild'] = {
  ['mana'] = { 20, 50, 100, 160, 240, 340 },
  ['cast'] = 0,
  ['level'] = { 1, 10, 20, 30, 40, 50 },
  ['text'] = {
    'Increases armor by 25.',
    'Increases armor by 65 and all attributes by 2.',
    'Increases armor by 105 and all attributes by 4.',
    'Increases armor by 150, all attributes by 6 and all resistances by 5.',
    'Increases armor by 195, all attributes by 8 and all resistances by 10.',
    'Increases armor by 240, all attributes by 10 and all resistances by 15.',
    'Increases armor by 285, all attributes by 12 and all resistances by 20.',
  }
}
spelldb['Thorns'] = {
  ['mana'] = { 35, 60, 105, 170, 240 },
  ['cast'] = 0,
  ['level'] = { 6, 14, 24, 34, 44 },
  ['text'] = {
    'Causes 3 Nature damage to attackers.',
    'Causes 6 Nature damage to attackers.',
    'Causes 9 Nature damage to attackers.',
    'Causes 12 Nature damage to attackers.',
    'Causes 15 Nature damage to attackers.',
    'Causes 18 Nature damage to attackers.',
  }
}

local update_player_auras = function()
  local player = party['player']
  player['auras'] = {}
  local id = 0
  while true do
    local index, _ = GetPlayerBuff(id) -- HARMFUL|HELPFUL|PASSIVE
    if index < 0 then break end
    local count = GetPlayerBuffApplications(index)
    local dispel = GetPlayerBuffDispelType(index)
    local duration = GetPlayerBuffTimeLeft(index)
    tooltip:SetPlayerBuff(index)
    local name = tooltipTextLeft1:GetText()
    local text = tooltipTextLeft2:GetText()
    player['auras'][name] = {}
    local buff = player['auras'][name]
    -- expire
    buff['duration'] = duration
    if spelldb[name] and spelldb[name]['text'] then
      for key, val in spelldb[name]['text'] do
        if val == text then
          buff['rank'] = key
          break
        end
      end
    end
    id = id + 1
  end
end

local dt, timer, timer0 = 1.0
main:SetScript('OnUpdate', function()
  if not timer then
    timer = GetTime()
    timer0 = ceil(timer + dt)
    debug(1, 'OnUpdate() ' .. timer .. ', ' .. timer0 .. ', arg1 = ' .. arg1)
    return
  end
  if update_auras then
    update_player_auras()
    update_auras = nil
  end
  timer = timer + arg1
  if timer >= timer0 then
    local t = GetTime()
    if not queue.empty(broadcast_q) then
      push_event_message(queue.pop(broadcast_q))
    end
    timer = t
    timer0 = timer0 + dt
    if timer0 <= t then timer0 = ceil(timer + dt) end
  end
end)

broadcast_events = {}

broadcast_events.SPELLCAST_START = function()
  local text = string.format("%.3f;SPELLCAST_START;%s;%s;", t, arg1, arg2)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.SPELLCAST_STOP = function()
  local text = string.format("%.3f;SPELLCAST_STOP;", t)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.SPELLCAST_INTERRUPTED = function()
  local text = string.format("%.3f;SPELLCAST_INTERRUPTED;", t)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.SPELLCAST_FAILED = function()
  local text = string.format("%.3f;SPELLCAST_FAILED;", t)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.SPELL_UPDATE_COOLDOWN = function()
  local text = string.format("%.3f;SPELL_UPDATE_COOLDOWN;", t)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.SPELLCAST_CHANNEL_START = function()
  local text = string.format("%.3f;SPELLCAST_CHANNEL_START;%s;", t, arg1)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.SPELLCAST_CHANNEL_STOP = function()
  local text = string.format("%.3f;SPELLCAST_CHANNEL_STOP;", t)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.SPELLCAST_CHANNEL_UPDATE = function()
  local text = string.format("%.3f;SPELLCAST_CHANNEL_UPDATE;%s;", t, arg1)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.START_AUTOREPEAT_SPELL = function()
  local text = string.format("%.3f;START_AUTOREPEAT_SPELL;", t)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

broadcast_events.STOP_AUTOREPEAT_SPELL = function()
  local text = string.format("%.3f;STOP_AUTOREPEAT_SPELL;", t)
  SendAddonMessage(prefix_event, text, 'PARTY')
end

combat_events = {}

combat_events.UNIT_HEALTH = function(unit)
  if not party[unit] then return end
  party[unit]['health'] = UnitHealth(unit)
  party_status()
end

combat_events.UNIT_MAXHEALTH = function(unit)
  if not party[unit] then return end
  party[unit]['health_max'] = UnitHealthMax(unit)
  party_status()
end

combat_events.UNIT_DISPLAYPOWER = function(unit)
  if not party[unit] then return end
  party[unit]['power_type'] = UnitPowerType(unit)
  party[unit]['power'] = UnitMana(unit)
  party[unit]['power_max'] = UnitManaMax(unit)
  party_status()
end

combat_events.UNIT_MANA = function(unit)
  if not party[unit] then return end
  party[unit]['power'] = UnitMana(unit)
  party_status()
end

combat_events.UNIT_MAXMANA = function(unit)
  if not party[unit] then return end
  party[unit]['power_max'] = UnitManaMax(unit)
  party_status()
end

combat_events.SPELL_DAMAGESHIELDS = function(msg)
  local amount
  local a, b, c, d
  a, b = strfind(msg, " reflect ", 0, true)
  if not a then a, b = strfind(msg, " reflects ", 0, true) end
  if a then
    ntu[1] = strsub(msg, 0, a - 1)
    c, d = strfind(msg, " ", b + 1, true)
    amount = strsub(msg, b + 1, c - 1)
    c, d = strfind(msg, " to ", d + 1, true)
    ntu[2] = strsub(msg, d + 1, -2)
    push_event_message(format_msg(t, 'DAMAGESHIELD', ntu[-1], amount, ntu[-2]))
    debug(0, format_chat(t, 'DAMAGESHIELD', COLOR_COMBAT, ntu[1], amount, ntu[2]))
    return
  end
end

combat_events.COMBAT_HITS = function(msg)
  local amount
  local a, b, c, d, e
  a, b = strfind(msg, " hits ", 0, true)
  if not a then a, b = strfind(msg, " hit ", 0, true) end
  if not a then a, b = strfind(msg, " crits ", 0, true) end
  if not a then a, b = strfind(msg, " crit ", 0, true) end
  if a then
    ntu[1] = strsub(msg, 0, a - 1)
    c, d = strfind(msg, " for ", b + 1, true)
    ntu[2] = strsub(msg, b + 1, c - 1)
    a, b = strfind(msg, ". (", d + 1, true)
    amount = strsub(msg, d + 1, (a or -1) - 1)
    local amount2
    if a then
      e, c, d = 'blocked', strfind(msg, " blocked", b + 1, true)
      if not c then e, c, d = 'absorbed', strfind(msg, " absorbed", b + 1, true) end
      if c then amount2 = strsub(msg, b + 1, c - 1) end
    end
    push_event_message(format_msg(t, 'MELEE', ntu[-1], amount, ntu[-2], amount2, e))
    debug(0, format_chat(t, 'MELEE', COLOR_COMBAT, ntu[1], amount, ntu[2]))
    return
  end
end

combat_events.COMBAT_MISSES = function(msg)
  local a, b, c, d, e
  a, b = strfind(msg, " attacks. ", 0, true)
  if not a then a, b = strfind(msg, " attack. ", 0, true) end
  if a then
    ntu[1] = strsub(msg, 0, a - 1)
    e, c, d = 'dodged', strfind(msg, " dodges.", b + 1, true)
    if not c then c, d = strfind(msg, " dodge.", b + 1, true) end
    if not c then e, c, d = 'parried', strfind(msg, " parries.", b + 1, true) end
    if not c then c, d = strfind(msg, " parry.", b + 1, true) end
    if not c then e, c, d = 'blocked', strfind(msg, " blocks.", b + 1, true) end
    if not c then c, d = strfind(msg, " block.", b + 1, true) end
    if not c then e, c, d = 'absorbed', strfind(msg, " absorbs all the damage.", b + 1, true) end
    if not c then c, d = strfind(msg, " absorb all the damage.", b + 1, true) end
    ntu[2] = strsub(msg, b + 1, c - 1)
    push_event_message(format_msg(t, 'MELEE', ntu[-1], e, ntu[-2]))
    return
  end
  a, b = strfind(msg, " misses ", 0, true)
  if not a then a, b = strfind(msg, " miss ", 0, true) end
  if a then
    ntu[1], ntu[2] = strsub(msg, 0, a - 1), strsub(msg, b + 1, -2)
    push_event_message(format_msg(t, 'MELEE', ntu[-1], 'missed', ntu[-2]))
    return
  end
end

combat_events.SPELL_DAMAGE = function(msg)
  local ability, amount, school, e, amount2
  local a, b, c, d
  a, b = strfind(msg, " hits ", 0, true)
  if not a then a, b = strfind(msg, " crits ", 0, true) end
  if a then
    c, d = strfind(msg, "'s ", 0, true)
    if not c then c, d = strfind(msg, " ", 0, true) end
    ntu[1] = strsub(msg, 0, c - 1)
    ability = strsub(msg, d + 1, a - 1)
    c, d = strfind(msg, " for ", b + 1, true)
    ntu[2] = strsub(msg, b + 1, c - 1)
    a, b = strfind(msg, " damage.", d + 1, true)
    if a then
      c = strfind(msg, " ", d + 1, true)
      school = strsub(msg, c + 1, a - 1)
    else
      c = strfind(msg, ".", d + 1, true)
    end
    amount = strsub(msg, d + 1, c - 1)
    a, b = strfind(msg, " (", (b or c) + 1, true)
    if a then
      e, c, d = 'resisted', strfind(msg, " resisted", b + 1, true)
      if not c then e, c, d = 'blocked', strfind(msg, " blocked", b + 1, true) end
      if not c then e, c, d = 'absorbed', strfind(msg, " absorbed", b + 1, true) end
      if c then amount2 = strsub(msg, b + 1, c - 1) end
    end
    push_event_message(format_msg(t, 'SPELL', ntu[-1], ability, amount, ntu[-2], amount2, e))
    debug(0, format_chat(t, 'SPELL', COLOR_COMBAT, ntu[1], ability, amount, ntu[2]))
    return
  end
  a, b = strfind(msg, " begins to cast ", 0, true)
  if a then
    ntu[1] = strsub(msg, 0, a - 1)
    ability = strsub(msg, b + 1, -2)
    debug(0, format_chat(t, 'BEGIN_SPELL', COLOR_COMBAT, ntu[1], ability))
    return
  end
  e, a, b = 'resisted', strfind(msg, " was resisted", 0, true)
  if not a then e, a, b = 'dodged', strfind(msg, " was dodged", 0, true) end
  if not a then e, a, b = 'parried', strfind(msg, " was parried", 0, true) end
  if not a then e, a, b = 'blocked', strfind(msg, " was blocked", 0, true) end
  if a then
    c, d = strfind(msg, "'s ", 0, true)
    if not c then c, d = strfind(msg, " ", 0, true) end
    ntu[1] = strsub(msg, 0, c - 1)
    ability = strsub(msg, d + 1, a - 1)
    c, d = strfind(msg, " by ", b + 1, true)
    if c then ntu[2] = strsub(msg, d + 1, -2) else ntu[2] = 'You' end
    push_event_message(format_msg(t, 'SPELL', ntu[-1], ability, e, ntu[-2]))
    debug(0, format_chat(t, 'SPELL', COLOR_COMBAT, ntu[1], ability, e, ntu[2]))
    return
  end
  e, a, b = 'missed', strfind(msg, " missed ", 0, true)
  if not a then a, b = strfind(msg, " misses ", 0, true) end
  if a then
    ntu[2] = strsub(msg, b + 1, -2)
    c, d = strfind(msg, "'s ", 0, true)
    if not c then c, d = strfind(msg, " ", 0, true) end
    ntu[1] = strsub(msg, 0, c - 1)
    ability = strsub(msg, d + 1, a - 1)
    push_event_message(format_msg(t, 'SPELL', ntu[-1], ability, e, ntu[-2]))
    return
  end
  e, a, b = 'absorbed', strfind(msg, " is absorbed by ", 0, true)
  if a then
    ntu[2] = strsub(msg, b + 1, -2)
    c, d = strfind(msg, "'s ", 0, true)
    if not c then c, d = strfind(msg, " ", 0, true) end
    ntu[1] = strsub(msg, 0, c - 1)
    ability = strsub(msg, d + 1, a - 1)
    push_event_message(format_msg(t, 'SPELL', ntu[-1], ability, e, ntu[-2]))
    return
  end
  a, b, ntu[1], ability, ntu[2] = strfind(msg, "You absorb (.-)'s (.-)%."), 'You'
  if a then
    push_event_message(format_msg(t, 'SPELL', ntu[-1], ability, e, ntu[-2]))
    return
  end
end

combat_events.SPELL_PERIODIC_DAMAGE = function(msg)
  local ability, amount, amount2, school
  local a, b, c, d, e
  a, b = strfind(msg, " suffers ", 0, true)
  if not a then a, b = strfind(msg, " suffer ", 0, true) end
  if a then
    ntu[2] = strsub(msg, 0, a - 1)
    c, d = strfind(msg, " ", b + 1, true)
    amount = strsub(msg, b + 1, c - 1)
    a, b = strfind(msg, " damage from ", d + 1, true)
    --school = strsub(msg, d + 1, a - 1)
    c, d = strfind(msg, "'s ", b + 1, true)
    if not c then c, d = strfind(msg, " ", b + 1, true) end
    ntu[1] = strsub(msg, b + 1, c - 1)
    a, b = strfind(msg, ". (", d + 1, true)
    ability = strsub(msg, d + 1, (a or -1) - 1)
    if a then
      e, c, d = 'resisted', strfind(msg, " resisted", b + 1, true)
      if not c then e, c, d = 'absorbed', strfind(msg, " absorbed", b + 1, true) end
      amount2 = strsub(msg, b + 1, c - 1)
    end
    push_event_message(format_msg(t, 'DOT', ntu[-1], ability, amount, ntu[-2], amount2, e))
    debug(0, format_chat(t, 'DOT', COLOR_COMBAT, ntu[1], ability, amount, ntu[2]))
    return
  end
  a, b = strfind(msg, " is afflicted by ", 0, true)
  if not a then a, b = strfind(msg, " are afflicted by ", 0, true) end
  if a then
    ntu[1] = strsub(msg, 0, a - 1)
    ability = strsub(msg, b + 1, -2)
    push_event_message(format_msg(t, 'AURA_GAIN', ability, ntu[-1]))
    debug(0, format_chat(t, 'AURA_GAIN', COLOR_COMBAT, ability, ntu[1]))
    local unit = ntu[-1]
    if party[unit] then
      if unit == 'player' then update_auras = 1 end
    end
    return
  end
  a, b = strfind(msg, " is absorbed by ", 0, true)
  if a then
    ntu[2] = strsub(msg, b + 1, -2)
    c, d = strfind(msg, "'s ", 0, true)
    ntu[1] = strsub(msg, 0, c - 1)
    ability = strsub(msg, d + 1, a - 1)
    push_event_message(format_msg(t, 'DOT', ntu[-1], ability, 'absorbed', ntu[-2]))
  end
  a, b = strfind(msg, " absorb ", 0, true)
  if a then
    ntu[2] = strsub(msg, 0, a - 1)
    c, d = strfind(msg, "'s ", b + 1, true)
    ntu[1] = strsub(msg, b + 1, c - 1)
    ability = strsub(msg, d + 1, -2)
    push_event_message(format_msg(t, 'DOT', ntu[-1], ability, 'absorbed', ntu[-2]))
  end
end

combat_events.SPELL_BUFF = function(msg)
  local ability, amount
  local a, b, c, d
  a, b = strfind(msg, " critically heals ", 0, true)
  if not a then a, b = strfind(msg, " heals ", 0, true) end
  if a then
    c, d = strfind(msg, "'s ", 0, true)
    if not c then c, d = strfind(msg, " ", 0, true) end
    ntu[1] = strsub(msg, 0, c - 1)
    ability = strsub(msg, d + 1, a - 1)
    c, d = strfind(msg, " for ", b + 1, true)
    ntu[2] = strsub(msg, b + 1, c - 1)
    amount = strsub(msg, d + 1, -2)
    push_event_message(format_msg(t, 'HEAL', ntu[-1], ability, amount, ntu[-2]))
    debug(0, format_chat(t, 'HEAL', COLOR_COMBAT, ntu[1], ability, amount, ntu[2]))
    return
  end
  a, b = strfind(msg, " begins to cast ", 0, true)
  if a then
    ntu[1] = strsub(msg, 0, a - 1)
    ability = strsub(msg, b + 1, -2)
    debug(0, format_chat(t, 'BEGIN_HEAL', COLOR_COMBAT, ntu[1], ability))
    return
  end
end

combat_events.SPELL_PERIODIC_BUFFS = function(msg)
  local ability, amount
  local a, b, c, d
  a, b = strfind(msg, " health from ", 0, true)
  if a then
    c, d = strfind(msg, " gain ", 0, true)
    if not c then c, d = strfind(msg, " gains ", 0, true) end
    ntu[2] = strsub(msg, 0, c - 1)
    amount = strsub(msg, d + 1, a - 1)
    c, d = strfind(msg, "'s ", b + 1, true)
    if not c then
      c, d = strfind(msg, "your ", b + 1, true) -- 'your' or '.'
      ntu[1] = 'You'
    else
      ntu[1] = strsub(msg, b + 1, c - 1)
    end
    ability = strsub(msg, (d or b) + 1, -2)
    push_event_message(format_msg(t, 'HOT', ntu[-1], ability, amount, ntu[-2]))
    debug(0, format_chat(t, 'HOT', COLOR_COMBAT, ntu[1], ability, amount, ntu[2]))
    return
  end
  a, b = strfind(msg, " from ", 0, true) -- Mana|Rage|Energy|Happiness
  if a then return end
  a, b = strfind(msg, " gain ", 0, true)
  if not a then a, b = strfind(msg, " gains ", 0, true) end
  if a then
    ntu[1] = strsub(msg, 0, a - 1)
    ability = strsub(msg, b + 1, -2)
    push_event_message(format_msg(t, 'AURA_GAIN', ability, ntu[-1]))
    debug(0, format_chat(t, 'AURA_GAIN', COLOR_COMBAT, ability, ntu[1]))
    local unit = ntu[-1]
    if party[unit] then
      if unit == 'player' then update_auras = 1 end
    end
    return
  end
end

combat_events.SPELL_AURA = function(msg)
  local ability
  local a, b
  a, b = strfind(msg, " fades from ", 0, true)
  if a then
    ability = strsub(msg, 0, a - 1)
    ntu[1] = strsub(msg, b + 1, -2)
    push_event_message(format_msg(t, 'AURA_GONE', ability, ntu[-1]))
    debug(0, format_chat(t, 'AURA_GONE', COLOR_COMBAT, ability, ntu[1]))
  end
end

combat_events.CHAT_MSG_SPELL_BREAK_AURA = function(msg)
  local ability
  local a, b, c, d
  a, b = strfind(msg, " is removed.", 0, true)
  if a then
    c, d = strfind(msg, "'s ", 0, true)
    if not c then c, d = strfind(msg, " ", 0, true) end
    ntu[1] = strsub(msg, 0, c - 1)
    ability = strsub(msg, d + 1, a - 1)
    push_event_message(format_msg(t, 'AURA_GONE', ability, ntu[-1]))
    debug(0, format_chat(t, 'AURA_GONE', COLOR_COMBAT, ability, ntu[1]))
  end
end

combat_events.CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS = combat_events.COMBAT_HITS
combat_events.CHAT_MSG_COMBAT_SELF_HITS = combat_events.COMBAT_HITS
combat_events.CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS = combat_events.COMBAT_HITS
combat_events.CHAT_MSG_COMBAT_PARTY_HITS = combat_events.COMBAT_HITS
combat_events.CHAT_MSG_COMBAT_PET_HITS = combat_events.COMBAT_HITS
combat_events.CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS = combat_events.COMBAT_HITS

combat_events.CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES = combat_events.COMBAT_MISSES
combat_events.CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES = combat_events.COMBAT_MISSES
combat_events.CHAT_MSG_COMBAT_SELF_MISSES = combat_events.COMBAT_MISSES
combat_events.CHAT_MSG_COMBAT_PARTY_MISSES = combat_events.COMBAT_MISSES
combat_events.CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES = combat_events.COMBAT_MISSES

combat_events.CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF = combat_events.SPELL_DAMAGESHIELDS
combat_events.CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS = combat_events.SPELL_DAMAGESHIELDS

combat_events.CHAT_MSG_SPELL_SELF_BUFF = combat_events.SPELL_BUFF
combat_events.CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF = combat_events.SPELL_BUFF

combat_events.CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS = combat_events.SPELL_PERIODIC_BUFFS
combat_events.CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS = combat_events.SPELL_PERIODIC_BUFFS
combat_events.CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS = combat_events.SPELL_PERIODIC_BUFFS

combat_events.CHAT_MSG_SPELL_SELF_DAMAGE = combat_events.SPELL_DAMAGE
combat_events.CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE = combat_events.SPELL_DAMAGE
combat_events.CHAT_MSG_SPELL_PARTY_DAMAGE = combat_events.SPELL_DAMAGE
combat_events.CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE = combat_events.SPELL_DAMAGE
combat_events.CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE = combat_events.SPELL_DAMAGE

combat_events.CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE = combat_events.SPELL_PERIODIC_DAMAGE
combat_events.CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE = combat_events.SPELL_PERIODIC_DAMAGE
combat_events.CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE = combat_events.SPELL_PERIODIC_DAMAGE
combat_events.CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE = combat_events.SPELL_PERIODIC_DAMAGE

combat_events.CHAT_MSG_SPELL_AURA_GONE_SELF = combat_events.SPELL_AURA
combat_events.CHAT_MSG_SPELL_AURA_GONE_PARTY = combat_events.SPELL_AURA

local parse_msg_addon = function(unit, msg, text)
  if msg == 'event' then
    local _, _, a, b, c, d = strfind(text, "(.-);(.-);([^;]*);?([^;]*);?")
    queue.push(broadcast_q, format_msg(a, b, unit, (c ~= '') and c, (d ~= '') and d))
  elseif msg == 'init' then
    queue.push(broadcast_q, unit .. text)
  end
end

local init_party = function()
  if leader_index == 0 then
    local unit = 'player'
    queue.push(broadcast_q, unit .. list_stats())
    queue.push(broadcast_q, unit .. list_auras())
    queue.push(broadcast_q, unit .. list_spells())
    queue.push(broadcast_q, unit .. list_talents())
  else
    local prefix = prefix .. '.init'
    SendAddonMessage(prefix, list_stats(), 'PARTY')
    SendAddonMessage(prefix, list_auras(), 'PARTY')
    SendAddonMessage(prefix, list_spells(), 'PARTY')
    SendAddonMessage(prefix, list_talents(), 'PARTY')
  end
  party_status()
end

local init_player = function()
  local unit, player = 'player', party['player']
  player['class'] = UnitClass(unit)
  player['health'] = UnitHealth(unit)
  player['health_max'] = UnitHealthMax(unit)
  player['power_type'] = UnitPowerType(unit)
  player['power'] = UnitMana(unit)
  player['power_max'] = UnitManaMax(unit)
  player['str'] = UnitStat(unit, 1)
  player['agi'] = UnitStat(unit, 2)
  player['sta'] = UnitStat(unit, 3)
  player['int'] = UnitStat(unit, 4)
  player['spi'] = UnitStat(unit, 5)
  player['defense'] = UnitDefense(unit)
  player['armor'] = UnitArmor(unit)
  update_player_auras()
  party[unit]['spells'] = {}
  local spells = party[unit]['spells']
  local rank = {}
  local id = 1
  while true do
    local name, subname = GetSpellName(id, BOOKTYPE_SPELL)
    if not name then break end
    if spelldb[name] then
      rank[name] = (rank[name] or 0) + 1
    end
    id = id + 1
  end
  for name, rank in rank do
    spells[name] = {}
    spells[name]['rank'] = rank
  end
  local talents = ''
  for tab = 1, 3 do
    local index = 1
    while true do
      local name, _, _, _, rank = GetTalentInfo(tab, index)
      if not name then break end
      talents = talents .. rank
      index = index + 1
    end
  end
  party[unit]['talents'] = talents
end

main_events = {}

main_events.PARTY_MEMBERS_CHANGED = function()
  debug(0, 'GetNumPartyMembers() = ' .. GetNumPartyMembers())
  local unit, name = 'player', party['player']['name']
  prefix = 'AngelPlayer.' .. name
  prefix_event = prefix .. '.event'
  ntu = { [name] = unit }
  for i = 1, 4 do
    unit = 'party' .. i
    if UnitIsConnected(unit) then
      name = UnitName(unit)
      ntu[name] = unit
      if not party[unit] or name ~= party[unit]['name'] then
        party[unit] = {}
        party[unit]['name'] = name
      end
      unit = 'partypet' .. i
      if UnitExists(unit) then
        name = UnitName(unit)
        party[unit] = {}
        party[unit]['name'] = name
        ntu[name] = unit
      end
    else
      party[unit] = nil
    end
  end
  setmetatable(ntu, ntu_meta)
end

main_events.PARTY_LEADER_CHANGED = function()
  local index = GetNumPartyMembers() > 0 and GetPartyLeaderIndex() or 0
  debug(0, 'GetPartyLeaderIndex() = ' .. index)
  if index == leader_index then return end
  leader_index = index
  if index == 0 then
    broadcast:UnregisterAllEvents()
    for i in combat_register_events do
      combat:RegisterEvent(combat_register_events[i])
    end
    main:Show()
  else
    combat:UnregisterAllEvents()
    for i in broadcast_register_events do
      broadcast:RegisterEvent(broadcast_register_events[i])
    end
    main:Hide()
  end
end

main_events.PLAYER_LOGIN = function()
  local unit = 'player'
  party[unit] = {}
  party[unit]['name'] = UnitName(unit)
  main_events.PARTY_MEMBERS_CHANGED()
  main_events.PARTY_LEADER_CHANGED()
  init_player()
end

main_events.CHAT_MSG_ADDON = function()
  local i, j, name, msg = strfind(arg1, "AngelPlayer%.(.-)%.(.+)")
  if not i then return end
  local unit = ntu[name]
  if unit == 'player' then return end
  if leader_index == 0 then
    parse_msg_addon(unit, msg, arg2)
  elseif unit == 'party' .. leader_index then
    if msg == 'init' then
      local b, name = 0
      for i = 1, 4 do
        _, b, name = strfind(arg2, "(.-)%.", b + 1)
        if not b then break end
        if name == party['player']['name'] then party_index = i break end
      end
      init_party()
    end
  end
end

broadcast:SetScript('OnEvent', function()
  debug(1, format_chat(nil, event, nil, arg1, arg2, arg3))
  if broadcast_events[event] then t = GetTime() broadcast_events[event](arg1, arg2, arg3) end
end)

combat:SetScript('OnEvent', function()
  debug(1, format_chat(nil, event, nil, arg1, arg2, arg3))
  if combat_events[event] then t = GetTime() combat_events[event](arg1) end
end)

main:SetScript('OnEvent', function()
  debug(1, format_chat(nil, event, nil, arg1, arg2, arg3))
  if main_events[event] then main_events[event](arg1, arg2, arg3) end
end)

local button = CreateFrame('BUTTON', nil, title, 'UIPanelButtonTemplate')
button:SetWidth(16)
button:SetHeight(16)
button:SetPoint('BOTTOMRIGHT', 0, 0)
button:SetScript('OnClick', function()
  init_party()
  local text = ''
  for i = 1, 4 do
    local unit = 'party' .. i
    if party[unit] then text = text .. party[unit]['name'] .. '.' end
  end
  SendAddonMessage('AngelPlayer.' .. party['player']['name'] .. '.init', text, 'PARTY')
end)