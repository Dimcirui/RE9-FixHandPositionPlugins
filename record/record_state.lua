-- ik_state_monitor.lua
-- F9 快照记录 motion layers + IK 状态
-- 输出: reframework/data/st_XXX.json

local dump_count = 0
local f9_was_down = false
local OFFSET_ENABLE = 16
local OFFSET_DISABLE = 24

local kb_singleton = sdk.get_native_singleton("via.hid.Keyboard")
local kb_typedef = sdk.find_type_definition("via.hid.Keyboard")
local key_f9 = nil
do
    local t = sdk.find_type_definition("via.hid.KeyboardKey")
    for _, f in ipairs(t:get_fields()) do
        if f:is_static() and f:get_name() == "F9" then
            key_f9 = f:get_data(nil); break
        end
    end
end

local function is_f9()
    if not kb_singleton or not key_f9 then return false end
    local dev = sdk.call_native_func(kb_singleton, kb_typedef, "get_Device")
    if not dev then return false end
    local ok, r = pcall(dev.call, dev, "isDown", key_f9)
    return ok and r
end

local function snap()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return end
    local scene = sdk.call_native_func(sm,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end

    local result = {}

    for _, go_name in ipairs({"cp_A100", "cp_A000"}) do
        local go = scene:call("findGameObject(System.String)", go_name)
        if not go then goto next end

        local entry = { layers = {}, status = {}, all_components = {} }

        local motion = go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
        if motion then
            local lc = motion:call("getLayerCount")
            if lc then
                -- 增加检测范围到 L15，实际游戏只到 L8 则只会提取存在的层
                for i = 0, math.min(lc - 1, 15) do
                    local layer = motion:call("getLayer", i)
                    if layer then
                        entry.layers["L" .. i] = {
                            b = layer:call("get_MotionBankID") or -1,
                            m = layer:call("get_MotionID") or -1,
                            bl = layer:call("get_BlendRate") or 0,
                        }
                    end
                end
            end
        end

        -- 新增：将角色身上的所有组件直接抓出来，写进 JSON
        entry.all_components = { "INIT_FLAG" }
        pcall(function()
            local clist = go:call("get_Components")
            if clist then
                local elements = clist:get_elements()
                for _, comp in ipairs(elements) do
                    if comp then
                        local td = comp:get_type_definition()
                        if td then
                            table.insert(entry.all_components, td:get_full_name())
                        end
                    end
                end
            else
                table.insert(entry.all_components, "ERROR_GET_COMPONENTS_FAILED")
            end
        end)

        -- 新增：针对 RE9 专属驱动器的深度探测
        entry.driver_data = {}
        local target_drivers = {
            "app.PlayerBattleStateDriver",
            "app.MentalStateDriver",
            "app.HeartRateDriver",
            "app.PlayerDebuffDriver",
            "app.SickSeizureControlDriver"
        }

        for _, driver_name in ipairs(target_drivers) do
            pcall(function()
                local comp = go:call("getComponent(System.Type)", sdk.typeof(driver_name))
                if comp then
                    entry.driver_data[driver_name] = {}
                    local td = comp:get_type_definition()
                    -- 遍历这个组件的所有字段（Health, isDying 等就藏在这里面）
                    for _, field in ipairs(td:get_fields()) do
                        -- 忽略静态字段和复杂对象，只抓取最基础的 BOOL, INT, FLOAT 值
                        if not field:is_static() then
                            local ok, val = pcall(function() return field:get_data(comp) end)
                            if ok and type(val) ~= "userdata" and type(val) ~= "function" then
                                -- 只保留数字或布尔值
                                if type(val) == "boolean" or type(val) == "number" then
                                    entry.driver_data[driver_name][field:get_name()] = val
                                end
                            end
                        end
                    end
                end
            end)
        end

        local acb = go:call("getComponent(System.Type)", sdk.typeof("anim.AnimationControllerBehavior"))
        if acb then
            local ac = acb:get_type_definition():get_field("AnimationController"):get_data(acb)
            if ac then
                local ab = ac:get_type_definition():get_field("AnimationBases"):get_data(ac)
                if ab then
                    local ok, count = pcall(ab.call, ab, "get_Count")
                    if ok and count then
                        for i = 0, count - 1 do
                            local ok_i, item = pcall(ab.call, ab, "get_Item(System.Int32)", i)
                            if ok_i and item then
                                local ok_t, td = pcall(item.get_type_definition, item)
                                if ok_t and td and td:get_full_name() == "anim.AnimLHandAdjustIK" then
                                    local f_br = td:get_field("<BlendRate>k__BackingField")
                                        or sdk.find_type_definition("anim.AnimationBase"):get_field("<BlendRate>k__BackingField")
                                    entry.ik = {
                                        en = item:read_qword(OFFSET_ENABLE),
                                        dis = item:read_qword(OFFSET_DISABLE),
                                        br = f_br and select(2, pcall(f_br.get_data, f_br, item)) or "?",
                                    }
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        result[go_name] = entry
        ::next::
    end

    dump_count = dump_count + 1
    local fn = "st_" .. string.format("%03d", dump_count) .. ".json"
    json.dump_file(fn, result)
    log.info("[Monitor] #" .. dump_count .. " -> " .. fn)
end

re.on_frame(function()
    local f9 = is_f9()
    if f9_was_down and not f9 then pcall(snap) end
    f9_was_down = f9
end)

re.on_draw_ui(function()
    if imgui.collapsing_header("IK State Monitor") then
        imgui.text("Press F9 to snapshot. Count: " .. dump_count)
    end
end)

log.info("[IK State Monitor] Loaded. F9 to snapshot.")