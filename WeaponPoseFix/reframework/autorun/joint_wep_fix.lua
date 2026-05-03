-- joint_wep_fix.lua
-- 结合 Github 原版优化：
-- 1. 采用离散关节追踪，支持多角色多骨骼独立偏移。
-- 2. 武器位移挂载在 LateUpdateBehavior 减震，手电筒挂载在 PrepareRendering 保证精度对齐。
-- 3. 支持位置 (Pos) 与旋转 (Rot) 的六轴偏移。
-- 4. 修复了暂停游戏时坐标无限叠加的漂移问题。

local CONFIG_DIR        = "WepJointFix/"
local IN_HAND_THRESHOLD = 0.011
local WEAPON_INTERVAL   = 0.5

-- 全局武器状态（兼容接口）
WeaponPoseFix               = WeaponPoseFix or {}
WeaponPoseFix.active_weapon = WeaponPoseFix.active_weapon or {}

------------------------------------------------------
-- 角色定义
------------------------------------------------------
local characters = {
    {
        name    = "Grace",
        go_names = {"cp_A100", "cp_A110"},
        enabled = true,
        joints  = {
            { name = "R_Wep", off_x = 0, off_y = 0, off_z = 0, off_rx = 0, off_ry = 0, off_rz = 0 },
            { name = "L_Wep", off_x = 0, off_y = 0, off_z = 0, off_rx = 0, off_ry = 0, off_rz = 0 },
        },
        flashlight = { _joint = nil, status = "Waiting...", x = 0, y = 0, z = 0 },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
        },
        _transform = nil, _go_ref = nil, _weapon_check_time = -999, _detected_weapon = nil,
        status = "Waiting...", write_count = 0, config_source = "default",
    },
    {
        name    = "Leon",
        go_names = {"cp_A000"},
        enabled = true,
        joints  = {
            { name = "R_Wep", off_x = 0, off_y = 0, off_z = 0, off_rx = 0, off_ry = 0, off_rz = 0 },
            { name = "L_Wep", off_x = 0, off_y = 0, off_z = 0, off_rx = 0, off_ry = 0, off_rz = 0 },
        },
        flashlight = { _joint = nil, status = "Waiting...", x = 0, y = 0, z = 0 },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm01", label = "Shotgun" },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
            { prefix = "arm06", label = "Sniper"  },
        },
        _transform = nil, _go_ref = nil, _weapon_check_time = -999, _detected_weapon = nil,
        status = "Waiting...", write_count = 0, config_source = "default",
    },
}

------------------------------------------------------
-- Math Helpers
------------------------------------------------------
local function quat_mul(a, b)
    return {
        x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
        y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
        z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
        w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,
    }
end

local function euler_to_quat(x, y, z)
    local cx = math.cos(x * 0.5); local sx = math.sin(x * 0.5)
    local cy = math.cos(y * 0.5); local sy = math.sin(y * 0.5)
    local cz = math.cos(z * 0.5); local sz = math.sin(z * 0.5)
    return {
        w = cx * cy * cz + sx * sy * sz,
        x = sx * cy * cz - cx * sy * sz,
        y = cx * sy * cz + sx * cy * sz,
        z = cx * cy * sz - sx * sy * cz
    }
end

------------------------------------------------------
-- IO / Config
------------------------------------------------------
local function cfg_path(char) return CONFIG_DIR .. "joint_wep_fix_" .. char.name .. ".json" end
local function save_config(char)
    local jdata = {}
    for _, j in ipairs(char.joints) do
        jdata[j.name] = { x = j.off_x, y = j.off_y, z = j.off_z, rx = j.off_rx, ry = j.off_ry, rz = j.off_rz }
    end
    json.dump_file(cfg_path(char), { enabled = char.enabled, joints = jdata })
    char.config_source = cfg_path(char)
end
local function load_config(char)
    local data = json.load_file(cfg_path(char))
    if data then
        char.enabled = (data.enabled ~= nil) and data.enabled or char.enabled
        if data.joints then
            for _, j in ipairs(char.joints) do
                local d = data.joints[j.name]
                if d then
                    j.off_x, j.off_y, j.off_z = d.x or 0, d.y or 0, d.z or 0
                    j.off_rx, j.off_ry, j.off_rz = d.rx or 0, d.ry or 0, d.rz or 0
                end
            end
        end
        char.config_source = cfg_path(char)
    end
end
for _, char in ipairs(characters) do load_config(char) end

------------------------------------------------------
-- Engine Helpers (Safe Natives)
------------------------------------------------------
local function joint_ok(j) return j and pcall(function() j:call("get_Position") end) end

local function ensure_transform(char)
    if char._go_ref then
        local is_drawn = false
        pcall(function() is_drawn = char._go_ref:call("get_DrawSelf") end)
        if not is_drawn then
            char._go_ref, char._transform = nil, nil
            char.status = "Hidden (DrawSelf=false)"
        end
    end
    if char._transform then return char._transform end

    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return nil end

    local go = nil
    for _, gname in ipairs(char.go_names) do
        local temp_go = scene:call("findGameObject(System.String)", gname)
        if temp_go then
            local is_drawn = false
            pcall(function() is_drawn = temp_go:call("get_DrawSelf") end)
            if is_drawn then
                go = temp_go
                break
            else
                char.status = "Hidden (DrawSelf=false)"
                return nil
            end
        end
    end
    
    if not go then 
        char.status = "Not in scene"
        return nil 
    end
    char._go_ref = go
    char._transform = go:call("get_Transform")
    return char._transform
end

local function update_weapon(char)
    if os.clock() - char._weapon_check_time < WEAPON_INTERVAL then return end
    char._weapon_check_time = os.clock()
    local t = char._transform
    if not t then return end
    
    local detected = nil
    pcall(function()
        -- 1. 先读取能显示的武器
        local visible_arms = {}
        local child = t:call("get_Child")
        while child do
            local cgo = child:call("get_GameObject")
            if cgo and cgo:call("get_Name"):sub(1,3) == "arm" then
                if cgo:call("get_DrawSelf") then
                    table.insert(visible_arms, { child = child, name = cgo:call("get_Name") })
                end
            end
            child = child:call("get_Next")
        end
        
        -- 2. 然后再去判定武器的距离
        for _, arm_info in ipairs(visible_arms) do
            local pos = arm_info.child:call("get_LocalPosition")
            if pos then
                local in_hand = math.abs(pos.x) < IN_HAND_THRESHOLD and
                                math.abs(pos.y) < IN_HAND_THRESHOLD and
                                math.abs(pos.z) < IN_HAND_THRESHOLD
                if in_hand then
                    for _, rule in ipairs(char.arm_weapon_map) do
                        if arm_info.name:sub(1, #rule.prefix) == rule.prefix then
                            detected = rule.label
                            break
                        end
                    end
                    if detected then break end
                end
            end
        end
    end)
    char._detected_weapon = detected
    WeaponPoseFix.active_weapon[char.name] = detected
end

------------------------------------------------------
-- Hooks
------------------------------------------------------
re.on_frame(function()
    for _, char in ipairs(characters) do
        if char.enabled and ensure_transform(char) then
            pcall(update_weapon, char)
            for _, j in ipairs(char.joints) do
                if not joint_ok(j._joint) then
                    j._joint = char._transform:call("getJointByName", j.name)
                end
                if joint_ok(j._joint) then
                    local p, r
                    pcall(function()
                        p = j._joint:call("get_LocalPosition")
                        r = j._joint:call("get_LocalRotation")
                    end)
                    if p then j._cur_pos = {x=p.x, y=p.y, z=p.z} end
                    if r then j._cur_rot = {x=r.x, y=r.y, z=r.z, w=r.w} end
                end
            end
            char.status = string.format("Active | weapon: %s | writes: %d", char._detected_weapon or "None", char.write_count)
        else
            if not char.enabled then
                char.status = "Disabled"
            end
        end
    end
end)

-- 武器位移：挂载在 LateUpdateBehavior 减震
re.on_pre_application_entry("LateUpdateBehavior", function()
    for _, char in ipairs(characters) do
        if char.enabled and char._transform then
            local written = false
            for _, j in ipairs(char.joints) do
                if joint_ok(j._joint) then
                    local lp, lr
                    pcall(function()
                        lp = j._joint:call("get_LocalPosition")
                        lr = j._joint:call("get_LocalRotation")
                    end)
                    if lp and lr then
                        local NEAR = 0.0001
                        local anim_p, anim_r
                        if j._last_target and math.abs(lp.x - j._last_target.x) < NEAR then anim_p = j._last_anim else anim_p = {x=lp.x, y=lp.y, z=lp.z} end
                        if j._last_target_r and math.abs(lr.x - j._last_target_r.x) < NEAR then anim_r = j._last_anim_r else anim_r = {x=lr.x, y=lr.y, z=lr.z, w=lr.w} end
                        
                        local tx, ty, tz = anim_p.x + j.off_x, anim_p.y + j.off_y, anim_p.z + j.off_z
                        local q_off = euler_to_quat(math.rad(j.off_rx), math.rad(j.off_ry), math.rad(j.off_rz))
                        local qr = quat_mul(anim_r, q_off)
                        
                        if math.abs(tx - lp.x) > 1e-5 or math.abs(qr.x - lr.x) > 1e-5 then
                            pcall(function()
                                j._joint:call("set_LocalPosition", Vector3f.new(tx, ty, tz))
                                local v_rot = j._joint:call("get_LocalRotation")
                                v_rot.x, v_rot.y, v_rot.z, v_rot.w = qr.x, qr.y, qr.z, qr.w
                                j._joint:call("set_LocalRotation", v_rot)
                            end)
                            written = true
                        end
                        j._last_anim, j._last_target = anim_p, {x=tx, y=ty, z=tz}
                        j._last_anim_r, j._last_target_r = anim_r, {x=qr.x, y=qr.y, z=qr.z, w=qr.w}
                    end
                end
            end
            if written then char.write_count = char.write_count + 1 end
        end
    end
end)

-- 手电筒对齐：挂载在 PrepareRendering 保精度
re.on_pre_application_entry("PrepareRendering", function()
    for _, char in ipairs(characters) do
        if char.enabled and char._transform then
            local fl = char.flashlight
            if not joint_ok(fl._joint) then
                pcall(function()
                    local t = char._transform
                    local child = t:call("get_Child")
                    while child do
                        local go = child:call("get_GameObject")
                        if go and go:call("get_Name") == "PlayerFlashLightController" then
                            local h = child:call("get_Child")
                            while h do
                                local h_go = h:call("get_GameObject")
                                if h_go and h_go:call("get_Name") == "HandLight" then
                                    local comp = h_go:get_component("app.WeaponReleaseFromHand")
                                    if comp then fl._joint = comp:get_field("_RootJoint") end
                                    break
                                end
                                h = h:call("get_Next")
                            end
                            break
                        end
                        child = child:call("get_Next")
                    end
                end)
            end
            if joint_ok(fl._joint) then
                local lw = char._transform:call("getJointByName", "L_Wep")
                if joint_ok(lw) then
                    pcall(function()
                        fl._joint:call("set_Position", lw:call("get_Position"))
                        fl._joint:call("set_Rotation", lw:call("get_Rotation"))
                    end)
                    fl.status = "Anchored to L_Wep"
                end
            end
        end
    end
end)

------------------------------------------------------
-- UI
------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.collapsing_header("Wep Joint Fix") then return end
    for _, char in ipairs(characters) do
        imgui.push_id(char.name)
        if imgui.tree_node(char.name) then
            local _, ne = imgui.checkbox("Enabled", char.enabled); if _ then char.enabled = ne end
            imgui.text("Status: " .. char.status)
            for _, j in ipairs(char.joints) do
                imgui.push_id(j.name)
                imgui.text(j.name .. (joint_ok(j._joint) and " [OK]" or " [LOST]"))
                local cx, vx = imgui.drag_float("Pos X", j.off_x, 0.0001, -0.5, 0.5, "%.4f"); if cx then j.off_x = vx end
                local cy, vy = imgui.drag_float("Pos Y", j.off_y, 0.0001, -0.5, 0.5, "%.4f"); if cy then j.off_y = vy end
                local cz, vz = imgui.drag_float("Pos Z", j.off_z, 0.0001, -0.5, 0.5, "%.4f"); if cz then j.off_z = vz end
                -- local rx, vrx = imgui.drag_float("Rot X", j.off_rx, 0.1, -180, 180, "%.1f"); if rx then j.off_rx = vrx end
                -- local ry, vry = imgui.drag_float("Rot Y", j.off_ry, 0.1, -180, 180, "%.1f"); if ry then j.off_ry = vry end
                -- local rz, vrz = imgui.drag_float("Rot Z", j.off_rz, 0.1, -180, 180, "%.1f"); if rz then j.off_rz = vrz end
                if imgui.button("Reset") then 
                    j.off_x, j.off_y, j.off_z = 0, 0, 0
                    -- j.off_rx, j.off_ry, j.off_rz = 0, 0, 0
                end
                imgui.spacing(); imgui.pop_id()
            end
            if imgui.button("Save") then save_config(char) end
            imgui.same_line()
            if imgui.button("Reload Config") then load_config(char) end
            imgui.tree_pop()
        end
        imgui.pop_id()
    end
end)
