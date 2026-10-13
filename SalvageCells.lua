--[[
SalvageCells
Windower 4 addon for original level-75 Salvage.

Behavior:
  NEED  -> lot one assigned copy of the cell
  OWNED -> pass further copies, auto-use the cell
  DONE  -> pass that cell for the rest of the current Salvage run

Multiple Windower clients coordinate over IPC so duplicate cells in the treasure
pool can be assigned to different characters that still need them.

v0.4.0:
  Adds automatic outside-Salvage cleanup.
  If the addon loads/logs in while outside original Salvage, any tracked imbued
  cells still sitting in Inventory are dropped automatically. These cells are
  run-specific and can interfere with a later Salvage entry.

v0.3.0:
  Persists per-character run state to disk.
  A DC, logout, or //lua r SalvageCells while still inside the same Salvage run
  restores NEED / OWNED / DONE / SKIP state instead of starting over.
  State is cleared when the character actually zones out of original Salvage.

IMPORTANT:
Disable any Treasury / LightLuggage rules that also auto-lot or auto-pass
Salvage cells. Two treasure managers fighting over the same pool item can
overwrite one another's lot/pass decisions.
]]

_addon.name = 'SalvageCells'
_addon.author = 'OpenAI'
_addon.version = '0.4.0'
_addon.commands = {'salvagecells', 'scells', 'sc'}

local packets = require('packets')
local texts = require('texts')

local SALVAGE_ZONES = {
    [73] = true, -- Zhayolm Remnants
    [74] = true, -- Arrapago Remnants
    [75] = true, -- Bhaflau Remnants
    [76] = true, -- Silver Sea Remnants
}

-- All original Salvage imbued cells.
-- Set any entry's required=false if you never want this addon to acquire it.
local CELLS = {
    [5365] = {name='Incus Cell',         alias='weapon',    effect='Weapons / shields',        required=true},
    [5366] = {name='Castellanus Cell',   alias='head',      effect='Head / neck',              required=true},
    [5367] = {name='Cumulus Cell',       alias='body',      effect='Body',                     required=true},
    [5368] = {name='Radiatus Cell',      alias='hands',     effect='Hands',                    required=true},
    [5369] = {name='Stratus Cell',       alias='legs',      effect='Legs / feet',              required=true},
    [5370] = {name='Cirrocumulus Cell',  alias='back',      effect='Back / waist',             required=true},
    [5371] = {name='Undulatus Cell',     alias='ranged',    effect='Ranged / ammo',            required=true},
    [5372] = {name='Virga Cell',         alias='rings',     effect='Rings / earrings',         required=true},
    [5373] = {name='Duplicatus Cell',    alias='subjob',    effect='Support job',              required=true},
    [5374] = {name='Opacus Cell',        alias='abilities', effect='Job abilities / WS',       required=true},
    [5375] = {name='Praecipitatio Cell', alias='magic',     effect='Magic',                    required=true},
    [5376] = {name='Pannus Cell',        alias='str',       effect='STR',                      required=true},
    [5377] = {name='Fractus Cell',       alias='dex',       effect='DEX',                      required=true},
    [5378] = {name='Congestus Cell',     alias='vit',       effect='VIT',                      required=true},
    [5379] = {name='Nimbus Cell',        alias='agi',       effect='AGI',                      required=true},
    [5380] = {name='Velum Cell',         alias='int',       effect='INT',                      required=true},
    [5381] = {name='Pileus Cell',        alias='mnd',       effect='MND',                      required=true},
    [5382] = {name='Mediocris Cell',     alias='chr',       effect='CHR',                      required=true},
    [5383] = {name='Humilus Cell',       alias='hp',        effect='Maximum HP',               required=true},
    [5384] = {name='Spissatus Cell',     alias='mp',        effect='Maximum MP',               required=true},
}

local ORDER = {
    5365, 5366, 5367, 5368, 5369, 5370, 5371, 5372,
    5373, 5374, 5375, 5376, 5377, 5378, 5379, 5380,
    5381, 5382, 5383, 5384,
}

local STATE_NEED  = 'n'
local STATE_OWNED = 'o'
local STATE_DONE  = 'd'
local STATE_SKIP  = 's'

local enabled = true
local active = false
local local_state = {}
local peers = {}
local pool_actions = {}
local last_inventory_count = {}
local last_use_attempt = {}
local last_tick = 0
local last_snapshot = 0
local sync_ready_at = 0
local run_started_at = 0
local persistence_warning_shown = false

local TICK_INTERVAL = 0.25
local SNAPSHOT_INTERVAL = 4.0
local PEER_TIMEOUT = 12
local USE_RETRY = 2.5
local SYNC_DELAY = 1.5
local PERSIST_MAX_AGE = 2 * 60 * 60 -- Salvage cannot legitimately survive longer.
local CLEANUP_DROP_DELAY = 0.30

local ui_enabled = true
local ui = nil

local UI_SETTINGS = {
    pos = {x = 25, y = 250},
    bg = {alpha = 160, red = 0, green = 0, blue = 0},
    text = {
        font = 'Consolas',
        size = 9,
        alpha = 255,
        red = 255,
        green = 255,
        blue = 255,
        stroke = {width = 1, alpha = 200, red = 0, green = 0, blue = 0},
    },
    flags = {
        draggable = true,
        bold = false,
        italic = false,
    },
    padding = 6,
}

local function chat(msg, color)
    windower.add_to_chat(color or 207, ('[%s] %s'):format(_addon.name, msg))
end

local function player()
    return windower.ffxi.get_player()
end

local function player_name()
    local p = player()
    return p and p.name or nil
end

local function current_zone()
    local info = windower.ffxi.get_info()
    return info and info.zone or nil
end

local function in_salvage()
    return SALVAGE_ZONES[current_zone()] == true
end

local function now_clock()
    return os.clock()
end

local function state_ui_parts(state)
    if state == STATE_NEED then
        return 'LOCK', 'LOT '
    elseif state == STATE_OWNED then
        return 'LOCK', 'USE '
    elseif state == STATE_DONE then
        return 'OPEN', 'PASS'
    else
        return 'SKIP', 'PASS'
    end
end

local function build_ui_text()
    local lines = {}

    lines[#lines + 1] = 'Salvage Cells'
    lines[#lines + 1] = '------------'
    lines[#lines + 1] = 'STATE ACTION CELL'

    for _, id in ipairs(ORDER) do
        local cell = CELLS[id]
        local state = local_state[id] or STATE_SKIP
        local lock_label, action_label = state_ui_parts(state)
        lines[#lines + 1] = string.format(
            '%-5s %-6s %s',
            lock_label,
            action_label,
            cell.alias
        )
    end

    lines[#lines + 1] = ''
    if active then
        lines[#lines + 1] = enabled and '[automation ON]' or '[automation OFF]'
    else
        lines[#lines + 1] = '[outside Salvage]'
    end

    return table.concat(lines, '\n')
end

local function ensure_ui()
    if ui then return end
    ui = texts.new('', UI_SETTINGS)
end

local function refresh_ui()
    ensure_ui()

    if not ui_enabled or not active then
        ui:hide()
        return
    end

    ui:text(build_ui_text())
    ui:show()
end

local function reset_local_state()
    for id, cell in pairs(CELLS) do
        local_state[id] = cell.required and STATE_NEED or STATE_SKIP
        last_inventory_count[id] = 0
        last_use_attempt[id] = 0
    end
    pool_actions = {}
end

local function serialize_state()
    local parts = {}
    for _, id in ipairs(ORDER) do
        parts[#parts + 1] = tostring(id) .. ':' .. (local_state[id] or STATE_SKIP)
    end
    return table.concat(parts, ',')
end

local function parse_state_string(payload)
    local states = {}
    for pair in payload:gmatch('[^,]+') do
        local id_s, state = pair:match('^(%d+):([nods])$')
        local id = tonumber(id_s)
        if id and CELLS[id] and state then
            states[id] = state
        end
    end
    return states
end

local function state_file_path()
    local name = player_name()
    if not name then return nil end

    local base = windower.addon_path or ''
    return base .. ('SalvageCells_%s.state'):format(name)
end

local function save_persisted_state()
    if not active then return end

    local path = state_file_path()
    if not path then return end

    local f = io.open(path, 'w')
    if not f then
        if not persistence_warning_shown then
            persistence_warning_shown = true
            chat('WARNING: could not write DC recovery state file.', 123)
        end
        return
    end

    f:write('version=1\n')
    f:write(('zone=%d\n'):format(current_zone() or 0))
    f:write(('started=%d\n'):format(run_started_at or 0))
    f:write(('saved=%d\n'):format(os.time()))
    f:write(('states=%s\n'):format(serialize_state()))
    f:close()
end

local function clear_persisted_state()
    local path = state_file_path()
    if path then
        os.remove(path)
    end
end

local function restore_persisted_state()
    local path = state_file_path()
    if not path then return false end

    local f = io.open(path, 'r')
    if not f then return false end

    local data = {}
    for line in f:lines() do
        local key, value = line:match('^([^=]+)=(.*)$')
        if key then
            data[key] = value
        end
    end
    f:close()

    local saved_zone = tonumber(data.zone)
    local saved_at = tonumber(data.saved)
    local saved_started = tonumber(data.started)
    local states = data.states and parse_state_string(data.states) or nil

    if saved_zone ~= current_zone() or not saved_at or not states then
        return false
    end

    local age = os.time() - saved_at
    if age < 0 or age > PERSIST_MAX_AGE then
        return false
    end

    reset_local_state()

    for id, state in pairs(states) do
        if CELLS[id] then
            local_state[id] = state
        end
    end

    run_started_at = saved_started or os.time()
    return true
end

local function party_names()
    local names = {}
    local seen = {}
    local party = windower.ffxi.get_party() or {}

    for _, member in pairs(party) do
        if type(member) == 'table'
            and member.name
            and member.name ~= ''
            and not seen[member.name]
        then
            seen[member.name] = true
            names[#names + 1] = member.name
        end
    end

    local me = player_name()
    if me and not seen[me] then
        names[#names + 1] = me
    end

    table.sort(names)
    return names, seen
end

local function is_party_member(name)
    if not name then return false end
    local _, seen = party_names()
    return seen[name] == true
end

local function update_self_peer()
    local me = player_name()
    if not me then return end

    peers[me] = peers[me] or {}
    peers[me].zone = current_zone()
    peers[me].states = {}

    for id, state in pairs(local_state) do
        peers[me].states[id] = state
    end

    peers[me].last_seen = os.time()
end

local function broadcast_snapshot()
    if not active then return end

    local me = player_name()
    local zone = current_zone()
    if not me or not zone then return end

    windower.send_ipc_message(
        ('SCELL|SNAP|%s|%d|%s'):format(me, zone, serialize_state())
    )
    last_snapshot = now_clock()
end

local function set_state(id, state, quiet)
    if not CELLS[id] then return end
    if local_state[id] == state then return end

    local_state[id] = state
    update_self_peer()
    save_persisted_state()
    broadcast_snapshot()
    refresh_ui()

    if not quiet then
        local labels = {
            [STATE_NEED]  = 'NEED',
            [STATE_OWNED] = 'OWNED',
            [STATE_DONE]  = 'DONE',
            [STATE_SKIP]  = 'SKIP',
        }
        chat(('%s -> %s (%s)'):format(
            CELLS[id].name,
            labels[state] or state,
            CELLS[id].effect
        ))
    end
end

local function inventory_count(item_id)
    local items = windower.ffxi.get_items()
    if not items or not items.inventory then return 0 end

    local count = 0
    for _, item in pairs(items.inventory) do
        if type(item) == 'table' and item.id == item_id then
            count = count + (item.count or 1)
        end
    end
    return count
end

local function collect_inventory_cells()
    local found = {}
    local items = windower.ffxi.get_items()

    if not items or not items.inventory then
        return found
    end

    for index, item in pairs(items.inventory) do
        if type(item) == 'table'
            and item.id
            and CELLS[item.id]
            and (item.count or 0) > 0
        then
            found[#found + 1] = {
                index = index,
                id = item.id,
                count = item.count or 1,
                name = CELLS[item.id].name,
            }
        end
    end

    table.sort(found, function(a, b)
        return a.index < b.index
    end)

    return found
end

local function drop_cell_entry(entry)
    -- Never allow an asynchronously scheduled cleanup drop to fire after the
    -- character has entered Salvage.
    if in_salvage() then
        return
    end

    local items = windower.ffxi.get_items()
    local current = items
        and items.inventory
        and items.inventory[entry.index]
        or nil

    -- Re-check the slot immediately before dropping it. Inventory can change
    -- between scheduling and execution.
    if type(current) == 'table'
        and current.id == entry.id
        and CELLS[current.id]
        and (current.count or 0) > 0
    then
        windower.ffxi.drop_item(entry.index, current.count)
        chat(('Dropping stale %s x%d from Inventory.'):format(
            CELLS[current.id].name,
            current.count
        ), 160)
    end
end

local function cleanup_cells_outside_salvage()
    if in_salvage() then
        return 0
    end

    local cells = collect_inventory_cells()

    if #cells == 0 then
        return 0
    end

    chat(('Outside Salvage: cleaning up %d stale cell slot%s.'):format(
        #cells,
        #cells == 1 and '' or 's'
    ), 123)

    for i, entry in ipairs(cells) do
        local captured = entry
        coroutine.schedule(function()
            drop_cell_entry(captured)
        end, (i - 1) * CLEANUP_DROP_DELAY)
    end

    return #cells
end

local function reconcile_restored_inventory()
    local changed = false

    for _, id in ipairs(ORDER) do
        local count = inventory_count(id)
        last_inventory_count[id] = count
        last_use_attempt[id] = 0

        -- We had already won the cell before the disconnect.
        -- If it is still present, keep OWNED and resume /item attempts.
        -- If it is gone, the most likely explanation is that its use completed
        -- just before the disconnect, so do not re-lot it.
        if local_state[id] == STATE_OWNED and count == 0 then
            local_state[id] = STATE_DONE
            changed = true
        elseif local_state[id] == STATE_NEED and count > 0 then
            local_state[id] = STATE_OWNED
            changed = true
        end
    end

    if changed then
        update_self_peer()
        save_persisted_state()
    end
end

local function mark_owned_cells()
    for _, id in ipairs(ORDER) do
        local count = inventory_count(id)
        local old_count = last_inventory_count[id] or 0

        if active and local_state[id] == STATE_NEED and count > 0 then
            set_state(id, STATE_OWNED, false)
        end

        -- Fallback success detector:
        -- if we tried to use a cell and the inventory count dropped, treat it as consumed.
        if active
            and local_state[id] == STATE_OWNED
            and old_count > count
            and (now_clock() - (last_use_attempt[id] or 0)) < 8.0
        then
            set_state(id, STATE_DONE, false)
        end

        last_inventory_count[id] = count
    end
end

local function try_use_owned_cells()
    if not active or not enabled then return end

    local t = now_clock()

    for _, id in ipairs(ORDER) do
        if local_state[id] == STATE_OWNED and inventory_count(id) > 0 then
            if t - (last_use_attempt[id] or 0) >= USE_RETRY then
                last_use_attempt[id] = t
                windower.send_command(
                    ('input /item "%s" <me>'):format(CELLS[id].name)
                )
                chat(('Using %s...'):format(CELLS[id].name), 8)
            end
        end
    end
end

local function prune_peers()
    local t = os.time()
    local me = player_name()

    for name, peer in pairs(peers) do
        if name ~= me then
            if not is_party_member(name)
                or peer.zone ~= current_zone()
                or (t - (peer.last_seen or 0)) > PEER_TIMEOUT
            then
                peers[name] = nil
            end
        end
    end
end

local function candidates_for(item_id)
    local names = {}
    local me = player_name()

    update_self_peer()
    prune_peers()

    for name, peer in pairs(peers) do
        if is_party_member(name) and peer.zone == current_zone() then
            local state = peer.states and peer.states[item_id]
            if state == STATE_NEED then
                names[#names + 1] = name
            end
        end
    end

    -- Always include self if we still need it, even during initial IPC convergence.
    if me and local_state[item_id] == STATE_NEED then
        local found = false
        for _, name in ipairs(names) do
            if name == me then
                found = true
                break
            end
        end

        if not found then
            names[#names + 1] = me
        end
    end

    -- v0.3 intentionally preserves the proven v0.2 deterministic allocation.
    -- Round-robin can be changed independently later without mixing it into the
    -- DC-recovery patch.
    table.sort(names)
    return names
end

local function act_on_pool_slot(slot, item_id, action)
    local fingerprint = tostring(item_id) .. ':' .. action

    if pool_actions[slot] == fingerprint then
        return
    end

    pool_actions[slot] = fingerprint

    if action == 'lot' then
        windower.ffxi.lot_item(slot)
        chat(('LOT %s (pool slot %d)'):format(CELLS[item_id].name, slot), 8)
    else
        windower.ffxi.pass_item(slot)
    end
end

local function scan_treasure()
    if not active or not enabled then return end
    if now_clock() < sync_ready_at then return end

    local items = windower.ffxi.get_items()
    if not items or not items.treasure then return end

    local grouped = {}
    local seen_slots = {}

    for slot, item in pairs(items.treasure) do
        if type(item) == 'table' and item.item_id and CELLS[item.item_id] then
            grouped[item.item_id] = grouped[item.item_id] or {}
            grouped[item.item_id][#grouped[item.item_id] + 1] = slot
            seen_slots[slot] = true
        end
    end

    -- Free cached decisions for treasure slots that no longer contain tracked cells.
    for slot, _ in pairs(pool_actions) do
        if not seen_slots[slot] then
            pool_actions[slot] = nil
        end
    end

    local me = player_name()
    if not me then return end

    for item_id, slots in pairs(grouped) do
        table.sort(slots)
        local candidates = candidates_for(item_id)

        for rank, slot in ipairs(slots) do
            local assigned = candidates[rank]

            -- If fewer characters need the item than copies currently in the pool,
            -- everyone passes the surplus copies.
            if assigned == me then
                act_on_pool_slot(slot, item_id, 'lot')
            else
                act_on_pool_slot(slot, item_id, 'pass')
            end
        end
    end
end

local function start_run(resume_allowed)
    active = true
    peers = {}
    pool_actions = {}
    persistence_warning_shown = false

    local restored = false

    if resume_allowed then
        restored = restore_persisted_state()
    end

    if restored then
        reconcile_restored_inventory()
        chat('Recovered current Salvage cell state after reload/DC.', 158)
    else
        reset_local_state()
        run_started_at = os.time()
        clear_persisted_state()
        save_persisted_state()
        chat('Original Salvage detected. New run state initialized.')
    end

    update_self_peer()
    sync_ready_at = now_clock() + SYNC_DELAY
    last_snapshot = 0
    refresh_ui()

    chat('IPC sync for party clients started; treasure decisions begin after 1.5 seconds.', 8)

    broadcast_snapshot()
    coroutine.schedule(broadcast_snapshot, 0.5)
    coroutine.schedule(broadcast_snapshot, 1.0)
end

local function stop_run()
    if active then
        chat('Left original Salvage. Run state and DC recovery file cleared.')
    end

    active = false
    peers = {}
    pool_actions = {}
    clear_persisted_state()
    refresh_ui()
end

local function resolve_cell(text)
    if not text or text == '' then return nil end
    text = text:lower()

    local as_number = tonumber(text)
    if as_number and CELLS[as_number] then
        return as_number
    end

    for id, cell in pairs(CELLS) do
        local full = cell.name:lower()
        local short = full:gsub('%s+cell$', '')

        if text == cell.alias
            or text == full
            or text == short
            or full:find(text, 1, true) == 1
        then
            return id
        end
    end

    return nil
end

local function print_status()
    local need, owned, done, skip = {}, {}, {}, {}

    for _, id in ipairs(ORDER) do
        local cell = CELLS[id]
        local label = cell.alias .. '=' .. cell.name
        local state = local_state[id]

        if state == STATE_NEED then
            need[#need + 1] = label
        elseif state == STATE_OWNED then
            owned[#owned + 1] = label
        elseif state == STATE_DONE then
            done[#done + 1] = label
        else
            skip[#skip + 1] = label
        end
    end

    local peer_count = 0
    for _ in pairs(peers) do
        peer_count = peer_count + 1
    end

    chat(('Active=%s Enabled=%s Zone=%s Peers=%d'):format(
        tostring(active),
        tostring(enabled),
        tostring(current_zone()),
        peer_count
    ))

    if #owned > 0 then chat('OWNED: ' .. table.concat(owned, ', '), 8) end
    if #need  > 0 then chat('NEED:  ' .. table.concat(need, ', '), 207) end
    if #done  > 0 then chat('DONE:  ' .. table.concat(done, ', '), 158) end
    if #skip  > 0 then chat('SKIP:  ' .. table.concat(skip, ', '), 160) end
end

local function print_help()
    chat('//sc status                  - show this character\'s run state')
    chat('//sc reset                   - reset all configured cells to NEED')
    chat('//sc need <alias/name/id>    - mark one cell NEED again')
    chat('//sc done <alias/name/id>    - manually mark one cell DONE')
    chat('//sc skip <alias/name/id>    - pass that cell for this run')
    chat('//sc on | off                - enable/disable treasure automation')
    chat('//sc sync                    - rebroadcast this client\'s state')
    chat('//sc ui on | off             - show/hide the status overlay')
    chat('//sc cleanup                 - drop stale Salvage cells outside Salvage')
    chat('Aliases: weapon head body hands legs back ranged rings subjob abilities magic str dex vit agi int mnd chr hp mp')
end

windower.register_event('ipc message', function(msg)
    if not active or type(msg) ~= 'string' then return end
    if msg:sub(1, 6) ~= 'SCELL|' then return end

    local kind, name, zone_s, payload =
        msg:match('^SCELL|([^|]+)|([^|]+)|([^|]+)|(.+)$')

    if kind ~= 'SNAP' or not name or not zone_s or not payload then return end
    if name == player_name() then return end
    if not is_party_member(name) then return end

    local zone = tonumber(zone_s)
    if zone ~= current_zone() then return end

    peers[name] = peers[name] or {}
    peers[name].zone = zone
    peers[name].states = parse_state_string(payload)
    peers[name].last_seen = os.time()
end)

-- Successful item use.
-- Windower's incoming action packet uses category 5 for item-use completion,
-- and Param is the used item ID.
windower.register_event('incoming chunk', function(id, data)
    if not active or id ~= 0x028 then return end

    local p = packets.parse('incoming', data)
    local me = player()

    if not p or not me then return end

    if p['Actor'] == me.id and p['Category'] == 5 then
        local item_id = p['Param']
        if CELLS[item_id] and local_state[item_id] == STATE_OWNED then
            set_state(item_id, STATE_DONE, false)
        end
    end
end)

windower.register_event('add item', function(bag, index, id, count)
    if not active or bag ~= 0 or not CELLS[id] then return end

    if local_state[id] == STATE_NEED then
        set_state(id, STATE_OWNED, false)
    end

    -- Tiny delay lets inventory tables finish updating before /item.
    coroutine.schedule(try_use_owned_cells, 0.25)
end)

windower.register_event('zone change', function(new_id, old_id)
    if SALVAGE_ZONES[new_id] then
        -- A real zone transition into Salvage is always a fresh run.
        start_run(false)
    elseif SALVAGE_ZONES[old_id] then
        -- A real zone transition out means this run is over for this character.
        stop_run()
    else
        active = false
        refresh_ui()
    end
end)

windower.register_event('load', function()
    ensure_ui()
    reset_local_state()

    if in_salvage() then
        -- Loading while already inside is the DC/reload recovery path.
        start_run(true)
    else
        -- Any stale state file cannot belong to an active run if we loaded outside.
        clear_persisted_state()
        refresh_ui()
        coroutine.schedule(cleanup_cells_outside_salvage, 1.0)
    end
end)

windower.register_event('login', function()
    if active then return end

    reset_local_state()

    if in_salvage() then
        start_run(true)
    else
        clear_persisted_state()
        refresh_ui()
        coroutine.schedule(cleanup_cells_outside_salvage, 1.0)
    end
end)

windower.register_event('prerender', function()
    if not active then return end

    local t = now_clock()
    if t - last_tick < TICK_INTERVAL then return end
    last_tick = t

    mark_owned_cells()
    try_use_owned_cells()
    scan_treasure()
    refresh_ui()

    if t - last_snapshot >= SNAPSHOT_INTERVAL then
        broadcast_snapshot()
    end
end)

-- Deliberately do NOT delete the recovery file on addon unload.
-- //lua r, a crash, logout, or Windower restart inside Salvage needs it.
windower.register_event('unload', function()
    if active then
        save_persisted_state()
    end

    if ui then
        ui:hide()
    end
end)

windower.register_event('addon command', function(command, ...)
    command = command and command:lower() or 'help'
    local args = {...}
    local text = table.concat(args, ' ')

    if command == 'status' then
        print_status()

    elseif command == 'reset' then
        reset_local_state()
        run_started_at = run_started_at ~= 0 and run_started_at or os.time()
        update_self_peer()
        save_persisted_state()
        sync_ready_at = now_clock() + 0.5
        broadcast_snapshot()
        refresh_ui()
        chat('Run state reset.')

    elseif command == 'need'
        or command == 'done'
        or command == 'skip'
    then
        local id = resolve_cell(text)

        if not id then
            chat(('Unknown cell "%s". Use //sc help for aliases.'):format(text), 123)
            return
        end

        local state =
            command == 'need' and STATE_NEED
            or command == 'done' and STATE_DONE
            or STATE_SKIP

        set_state(id, state, false)

    elseif command == 'on' then
        enabled = true
        refresh_ui()
        chat('Automation enabled.')
        sync_ready_at = now_clock() + 0.5
        broadcast_snapshot()

    elseif command == 'off' then
        enabled = false
        refresh_ui()
        chat('Automation disabled.')

    elseif command == 'ui' then
        local choice = (args[1] or ''):lower()

        if choice == 'on' then
            ui_enabled = true
            refresh_ui()
            chat('Status overlay enabled.')
        elseif choice == 'off' then
            ui_enabled = false
            refresh_ui()
            chat('Status overlay disabled.')
        else
            chat('Usage: //sc ui on  OR  //sc ui off')
        end

    elseif command == 'cleanup' then
        if in_salvage() then
            chat('Cleanup refused: currently inside original Salvage.', 123)
        else
            local count = cleanup_cells_outside_salvage()
            if count == 0 then
                chat('No stale Salvage cells found in Inventory.', 158)
            end
        end

    elseif command == 'sync' then
        update_self_peer()
        save_persisted_state()
        broadcast_snapshot()
        chat('State snapshot broadcast.')

    else
        print_help()
    end
end)
