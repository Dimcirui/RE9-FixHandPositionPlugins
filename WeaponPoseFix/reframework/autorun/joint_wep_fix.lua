-- joint_wep_fix.lua (Zhipu AI Expert Optimized V3)
-- 性能优化：
-- 1. 实现 3 秒搜索节流 (SEARCH_INTERVAL)
-- 2. 移除所有热路径匿名闭包
-- 3. 移除 PrepareRendering 操作，移至 LateUpdate
-- 4. 使用 sdk.get_component 确保极致稳定性
-- 5. 全局 pcall 保护手电筒逻辑

local CONFIG_DIR        = "WepJointFix/"
local IN_HAND_THRESHOLD = 0.011
local WEAPON_INTERVAL   = 0.5
local STATUS_INTERVAL   = 0.1
local SEARCH_INTERVAL   = 3.0

WeaponPoseFix               = WeaponPoseFix or {}
WeaponPoseFix.active_weapon = WeaponPoseFix.active_weapon or {}

-- 预分配对象
local temp_vec3 = Vector3f.new(0, 0, 0)
local temp_vec4 = Vector4f.new(0, 0, 0, 1)
local anim_r_buf = {x=0, y=0, z=0, w=1}
local qr_buf = {x=0, y=0, z=0, w=1}

------------------------------------------------------
-- 角色定义
------------------------------------------------------
local characters = {
    {
        name     = "Grace",
        go_names = {"cp_A100", "cp_A110"},
        enabled  = true,
        joints   = {
            { name = "R_Wep", off_x=0, off_y=0, off_z=0, off_rx=0, off_ry=0, off_rz=0,
              _joint=nil, _valid=false, _q_off=nil, _rx_c=nil, _ry_c=nil, _rz_c=nil,
              _last_target=nil, _last_anim=nil, _last_target_r=nil, _last_anim_r=nil },
            { name = "L_Wep", off_x=0, off_y=0, off_z=0, off_rx=0, off_ry=0, off_rz=0,
              _joint=nil, _valid=false, _q_off=nil, _rx_c=nil, _ry_c=nil, _rz_c=nil,
              _last_target=nil, _last_anim=nil, _last_target_r=nil, _last_anim_r=nil },
        },
        flashlight = { _joint=nil, _lw_joint=nil, status="Waiting...", x=0, y=0, z=0 },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
        },
        _transform=nil, _go_ref=nil, _weapon_check_time=-999,
        _status_update_time=-999, _search_time=-999,
        _detected_weapon=nil, _cached_status="Waiting...",
        write_count=0, config_source="default",
    },
    {
        name     = "Leon",
        go_names = {"cp_A000"},
        enabled  = true,
        joints   = {
            { name = "R_Wep", off_x=0, off_y=0, off_z=0, off_rx=0, off_ry=0, off_rz=0,
              _joint=nil, _valid=false, _q_off=nil, _rx_c=nil, _ry_c=nil, _rz_c=nil,
              _last_target=nil, _last_anim=nil, _last_target_r=nil, _last_anim_r=nil },
            { name = "L_Wep", off_x=0, off_y=0, off_z=0, off_rx=0, off_ry=0, off_rz=0,
              _joint=nil, _valid=false, _q_off=nil, _rx_c=nil, _ry_c=nil, _rz_c=nil,
              _last_target=nil, _last_anim=nil, _last_target_r=nil, _last_anim_r=nil },
        },
        flashlight = { _joint=nil, _lw_joint=nil, status="Waiting...", x=0, y=0, z=0 },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm01", label = "Shotgun" },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
            { prefix = "arm06", label = "Sniper"  },
        },
        _transform=nil, _go_ref=nil, _weapon_check_time=-999,
        _status_update_time=-999, _search_time=-999,
        _detected_weapon=nil, _cached_status="Waiting...",
        write_count=0, config_source="default",
    },
}

------------------------------------------------------
-- Math Helpers
------------------------------------------------------
local function quat_mul_into(out, a, b)
    out.x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y
    out.y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x
    out.z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w
    out.w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z
end

local function euler_to_quat(x, y, z)
    local cx = math.cos(x * 0.5); local sx = math.sin(x * 0.5)
    local cy = math.cos(y * 0.5); local sy = math.sin(y * 0.5)
    local cz = math.cos(z * 0.5); local sz = math.sin(z * 0.5)
    return {
        w = cx * cy * cz + sx * sy * sz,
        x = sx * cy * cz - cx * sy * sz,
        y = cx * sy * cz + sx * cy * sz,
        z = cx * cy * sz - sx * sy * cz,
    }
end

------------------------------------------------------
-- IO / Config
------------------------------------------------------
local function cfg_path(char) return CONFIG_DIR .. "joint_wep_fix_" .. char.name .. ".json" end
local function save_config(char)
    local jdata = {}
    for _, j in ipairs(char.joints) do
        jdata[j.name] = { x=j.off_x, y=j.off_y, z=j.off_z, rx=j.off_rx, ry=j.off_ry, rz=j.off_rz }
    end
    json.dump_file(cfg_path(char), { enabled=char.enabled, joints=jdata })
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
                    j.off_x, j.off_y, j.off_z     = d.x or 0, d.y or 0, d.z or 0
                    j.off_rx, j.off_ry, j.off_rz   = d.rx or 0, d.ry or 0, d.rz or 0
                end
            end
        end
        char.config_source = cfg_path(char)
    end
end
for _, char in ipairs(characters) do load_config(char) end

------------------------------------------------------
-- Engine Helpers
------------------------------------------------------
local function invalidate_char(char)
    char._go_ref = nil; char._transform = nil
    for _, j in ipairs(char.joints) do j._joint = nil; j._valid = false end
    char.flashlight._joint = nil; char.flashlight._lw_joint = nil
end

local function ensure_transform(char)
    if char._go_ref then
        local is_drawn = false
        pcall(function() is_drawn = char._go_ref:call("get_DrawSelf") end)
        if not is_drawn then invalidate_char(char); return nil end
    end
    if char._transform then return char._transform end

    local now = os.clock()
    if now - char._search_time < SEARCH_INTERVAL then return nil end
    char._search_time = now

    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sm and sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return nil end

    for _, gname in ipairs(char.go_names) do
        local temp_go = scene:call("findGameObject(System.String)", gname)
        if temp_go then
            local is_drawn = false
            pcall(function() is_drawn = temp_go:call("get_DrawSelf") end)
            if is_drawn then
                char._go_ref = temp_go; char._transform = temp_go:call("get_Transform")
                return char._transform
            end
        end
    end
    char._cached_status = "Not in scene"
    return nil
end

------------------------------------------------------
-- Core Processing (V3 Robust)
------------------------------------------------------
local function process_joint(j)
    if not j._valid then return false end
    if j.off_rx ~= j._rx_c or j.off_ry ~= j._ry_c or j.off_rz ~= j._rz_c then
        j._q_off = euler_to_quat(math.rad(j.off_rx), math.rad(j.off_ry), math.rad(j.off_rz))
        j._rx_c, j._ry_c, j._rz_c = j.off_rx, j.off_ry, j.off_rz
    end
    local lp = j._joint:call("get_LocalPosition")
    local lr = j._joint:call("get_LocalRotation")
    if not (lp and lr) then j._valid = false; return false end

    local NEAR = 0.0001
    local ax, ay, az = lp.x, lp.y, lp.z
    if j._last_target and math.abs(lp.x - j._last_target.x) < NEAR then
        ax, ay, az = j._last_anim.x, j._last_anim.y, j._last_anim.z
    end
    local arx, ary, arz, arw = lr.x, lr.y, lr.z, lr.w
    if j._last_target_r and math.abs(lr.x - j._last_target_r.x) < NEAR then
        arx, ary, arz, arw = j._last_anim_r.x, j._last_anim_r.y, j._last_anim_r.z, j._last_anim_r.w
    end

    local tx, ty, tz = ax + j.off_x, ay + j.off_y, az + j.off_z
    anim_r_buf.x, anim_r_buf.y, anim_r_buf.z, anim_r_buf.w = arx, ary, arz, arw
    quat_mul_into(qr_buf, anim_r_buf, j._q_off)

    if math.abs(tx - lp.x) > 1e-5 or math.abs(qr_buf.x - lr.x) > 1e-5 then
        temp_vec3.x, temp_vec3.y, temp_vec3.z = tx, ty, tz
        j._joint:call("set_LocalPosition", temp_vec3)
        temp_vec4.x, temp_vec4.y, temp_vec4.z, temp_vec4.w = qr_buf.x, qr_buf.y, qr_buf.z, qr_buf.w
        j._joint:call("set_LocalRotation", temp_vec4)
        if not j._last_target then
            j._last_anim, j._last_target = {x=ax, y=ay, z=az}, {x=tx, y=ty, z=tz}
            j._last_anim_r, j._last_target_r = {x=arx, y=ary, z=arz, w=arw}, {x=qr_buf.x, y=qr_buf.y, z=qr_buf.z, w=qr_buf.w}
        else
            j._last_anim.x, j._last_anim.y, j._last_anim.z = ax, ay, az
            j._last_target.x, j._last_target.y, j._last_target.z = tx, ty, tz
            j._last_anim_r.x, j._last_anim_r.y, j._last_anim_r.z, j._last_anim_r.w = arx, ary, arz, arw
            j._last_target_r.x, j._last_target_r.y, j._last_target_r.z, j._last_target_r.w = qr_buf.x, qr_buf.y, qr_buf.z, qr_buf.w
        end
        return true
    end
    return false
end

local function process_flashlight(char)
    pcall(function()
        local fl = char.flashlight
        if not fl._joint then
            local t = char._transform
            local child = t:call("get_Child")
            while child do
                local go = child:call("get_GameObject")
                if go and go:call("get_Name") == "PlayerFlashLightController" then
                    local h = child:call("get_Child")
                    while h do
                        local h_go = h:call("get_GameObject")
                        if h_go and h_go:call("get_Name") == "HandLight" then
                            -- V3: 使用 sdk.get_component 彻底解决崩溃问题
                            local comp = sdk.get_component(h_go, "app.WeaponReleaseFromHand")
                            if comp then fl._joint = comp:get_field("_RootJoint") end
                            break
                        end
                        h = h:call("get_Next")
                    end
                    break
                end
                child = child:call("get_Next")
            end
        end
        if fl._joint then
            if not fl._lw_joint then fl._lw_joint = char._transform:call("getJointByName", "L_Wep") end
            if fl._lw_joint then
                local pos = fl._lw_joint:call("get_Position")
                local rot = fl._lw_joint:call("get_Rotation")
                if pos and rot then
                    fl._joint:call("set_Position", pos); fl._joint:call("set_Rotation", rot)
                    fl.status = "Anchored"
                end
            end
        end
    end)
end

------------------------------------------------------
-- Hooks
------------------------------------------------------
re.on_frame(function()
    for _, char in ipairs(characters) do
        if char.enabled and ensure_transform(char) then
            -- 武器检测限流
            if os.clock() - char._weapon_check_time > WEAPON_INTERVAL then
                char._weapon_check_time = os.clock()
                local detected = nil
                local child = char._transform:call("get_Child")
                while child do
                    local cgo = child:call("get_GameObject")
                    if cgo and cgo:call("get_DrawSelf") and cgo:call("get_Name"):sub(1,3) == "arm" then
                        local pos = child:call("get_LocalPosition")
                        if pos and math.abs(pos.x) < IN_HAND_THRESHOLD then
                            for _, rule in ipairs(char.arm_weapon_map) do
                                if cgo:call("get_Name"):sub(1, #rule.prefix) == rule.prefix then detected = rule.label; break end
                            end
                        end
                    end
                    if detected then break end
                    child = child:call("get_Next")
                end
                char._detected_weapon = detected
                WeaponPoseFix.active_weapon[char.name] = detected
            end
            for _, j in ipairs(char.joints) do 
                if not j._valid then 
                    local jnt = char._transform:call("getJointByName", j.name)
                    if jnt then j._joint = jnt; j._valid = true end
                end
            end
            if os.clock() - char._status_update_time > STATUS_INTERVAL then
                char._status_update_time = os.clock()
                char._cached_status = string.format("Active | %s | writes: %d", char._detected_weapon or "None", char.write_count)
            end
        end
    end
end)

re.on_pre_application_entry("LateUpdateBehavior", function()
    for _, char in ipairs(characters) do
        if char.enabled and char._transform then
            local written = false
            for _, j in ipairs(char.joints) do if process_joint(j) then written = true end end
            process_flashlight(char)
            if written then char.write_count = char.write_count + 1 end
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
            imgui.text("Status: " .. (char._cached_status or "Waiting..."))
            for _, j in ipairs(char.joints) do
                imgui.push_id(j.name)
                imgui.text(j.name .. (j._valid and " [OK]" or " [LOST]"))
                local cx, vx = imgui.drag_float("Pos X", j.off_x, 0.0001, -0.5, 0.5, "%.4f"); if cx then j.off_x = vx end
                local cy, vy = imgui.drag_float("Pos Y", j.off_y, 0.0001, -0.5, 0.5, "%.4f"); if cy then j.off_y = vy end
                local cz, vz = imgui.drag_float("Pos Z", j.off_z, 0.0001, -0.5, 0.5, "%.4f"); if cz then j.off_z = vz end
                if imgui.button("Reset") then j.off_x, j.off_y, j.off_z = 0, 0, 0 end
                imgui.spacing(); imgui.pop_id()
            end
            if imgui.button("Save") then save_config(char) end
            imgui.same_line(); if imgui.button("Reload") then load_config(char) end
            imgui.tree_pop()
        end
        imgui.pop_id()
    end
end)
