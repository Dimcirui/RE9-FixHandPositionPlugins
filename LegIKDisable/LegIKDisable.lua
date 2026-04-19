-- LegIKDisable.lua  v1.1
-- Quick toggle to disable leg IK via anim.AnimIkLeg's DelayIkMode field
-- Path: anim.AnimIkLeg -> LegParams[0/1] -> IK (IKInfo) -> DelayIkMode
-- Support characters: cp_A100 (Grace), cp_A000 (Leon)

local CONFIG_FILE = "LHandIKFix/leg_ik_disable.json"

local cfg = {
    enabled = false,  -- when true, leg IK is disabled (DelayIkMode = true on both feet)
}

local characters = {
    { name = "Grace", go_name = "cp_A100" },
    { name = "Leon",  go_name = "cp_A000" },
}

for _, char in ipairs(characters) do
    char._go_ref   = nil
    char._ik_item  = nil
    char.ik_disabled = false
    char.status    = "Waiting..."
end

------------------------------------------------------
-- Config
------------------------------------------------------
local function load_config()
    local data = json.load_file(CONFIG_FILE)
    if data and data.enabled ~= nil then
        cfg.enabled = data.enabled
    end
end

local function save_config()
    json.dump_file(CONFIG_FILE, { enabled = cfg.enabled })
end

load_config()

------------------------------------------------------
-- Core: find anim.AnimIkLeg item
------------------------------------------------------
local function find_leg_ik_item(char, go)
    if char._ik_item then
        local ok = pcall(function() return char._ik_item:get_address() end)
        if ok then return char._ik_item end
        char._ik_item = nil
    end

    local acb = go:call("getComponent(System.Type)", sdk.typeof("anim.AnimationControllerBehavior"))
    if not acb then return nil end
    local ac = acb:get_type_definition():get_field("AnimationController"):get_data(acb)
    if not ac then return nil end
    local ab = ac:get_type_definition():get_field("AnimationBases"):get_data(ac)
    if not ab then return nil end
    local ok, count = pcall(ab.call, ab, "get_Count")
    if not ok or not count then return nil end
    for i = 0, count - 1 do
        local ok_i, item = pcall(ab.call, ab, "get_Item(System.Int32)", i)
        if ok_i and item then
            local ok_t, td = pcall(item.get_type_definition, item)
            if ok_t and td and td:get_full_name() == "anim.AnimIkLeg" then
                char._ik_item = item
                return item
            end
        end
    end
    return nil
end

-- Known offsets (from type_meta inspection)
local OFFSET_LEG_PARAMS  = 656  -- anim.AnimIkLeg.LegParams
local OFFSET_IK          = 160  -- anim.AnimIkLeg.LegParam.IK
local OFFSET_DELAYIKMODE = 112  -- anim.AnimIKHelper.IKInfo.DelayIkMode

------------------------------------------------------
-- Core: set DelayIkMode on all LegParams[i].IK
-- Uses write_byte directly to avoid set_data bool quirks
------------------------------------------------------
local function set_leg_delay_mode(item, delay_mode)
    -- Step 1: get LegParams array via field API (reference type, returns real ref)
    local ok_td, td = pcall(item.get_type_definition, item)
    if not ok_td or not td then return false end
    local ok_lf, lp_field = pcall(td.get_field, td, "LegParams")
    if not ok_lf or not lp_field then return false end
    local ok_arr, arr = pcall(lp_field.get_data, lp_field, item)
    if not ok_arr or not arr then return false end

    local ok_sz, sz = pcall(arr.get_size, arr)
    if not ok_sz or not sz then return false end

    local byte_val = delay_mode and 1 or 0
    for j = 0, sz - 1 do
        local ok_el, el = pcall(arr.call, arr, "get_Item(System.Int32)", j)
        if ok_el and el then
            -- Step 2: get IKInfo via field API
            local ok_etd, etd = pcall(el.get_type_definition, el)
            if ok_etd and etd then
                local ok_ikf, ik_field = pcall(etd.get_field, etd, "IK")
                if ok_ikf and ik_field then
                    local ok_ikv, ik = pcall(ik_field.get_data, ik_field, el)
                    -- Step 3: write_byte directly at known offset instead of set_data
                    if ok_ikv and ik then
                        pcall(ik.write_byte, ik, OFFSET_DELAYIKMODE, byte_val)
                    end
                end
            end
        end
    end
    return true
end

------------------------------------------------------
-- Restore all characters' leg IK
------------------------------------------------------
local function restore_all()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return end
    local scene = sdk.call_native_func(sm,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end
    for _, char in ipairs(characters) do
        if char._go_ref then
            local item = find_leg_ik_item(char, char._go_ref)
            if item then pcall(set_leg_delay_mode, item, false) end
        end
        char.ik_disabled = false
        char.status = "Leg IK restored"
    end
end

------------------------------------------------------
-- Main loop
------------------------------------------------------
local prev_enabled = cfg.enabled
local last_check   = -999
local CHECK_INTERVAL = 0.1

re.on_frame(function()
    -- Handle toggle-off: restore DelayIkMode to false immediately
    if prev_enabled and not cfg.enabled then
        pcall(restore_all)
    end
    prev_enabled = cfg.enabled

    if not cfg.enabled then return end

    local now = os.clock()
    if now - last_check < CHECK_INTERVAL then return end
    last_check = now

    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return end
    local scene = sdk.call_native_func(sm,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end

    for _, char in ipairs(characters) do
        local go = char._go_ref
        if go then
            local ok = pcall(function() return go:get_Name() end)
            if not ok then go = nil end
        end
        if not go then
            go = scene:call("findGameObject(System.String)", char.go_name)
            char._go_ref = go
        end

        if go then
            local item = find_leg_ik_item(char, go)
            if item then
                local ok = pcall(set_leg_delay_mode, item, true)
                char.ik_disabled = ok
                char.status = ok and "Leg IK disabled" or "Failed to set DelayIkMode"
            else
                char.status = "AnimIkLeg not found"
            end
        else
            char.status      = "Not in scene"
            char._go_ref     = nil
            char._ik_item    = nil
            char.ik_disabled = false
        end
    end
end)

------------------------------------------------------
-- UI
------------------------------------------------------
re.on_draw_ui(function()
    if imgui.collapsing_header("IK Leg Fix") then
        local changed, new_val = imgui.checkbox("Disable Leg IK", cfg.enabled)
        if changed then
            cfg.enabled = new_val
            save_config()
        end
        imgui.separator()
        for _, char in ipairs(characters) do
            imgui.text(char.name .. " (" .. char.go_name .. "): " .. char.status)
        end
    end
end)

log.info("[IK Leg Fix] Loaded.")
