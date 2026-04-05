-- joint_wep_fix.lua
-- 结合 Github 原版：
-- 1. 回收分离参数，全局只控制一组 R_Wep 和 L_Wep 的 X/Y/Z。
-- 2. 完美保留武器分类功能 (arm_weapon_map)，它会继续精准探测并把 "Pistol" / "Shotgun" 输出给全局表 WeaponPoseFix.active_weapon，供你的 IK 脚本读取。
-- 3. 采用四元数换算算法替换了导致抖动的基准旋转检测。

local CONFIG_DIR        = "WepJointFix/"
local IN_HAND_THRESHOLD = 0.011
local WEAPON_INTERVAL   = 0.5

-- 全局武器状态（兼容 WeaponPoseFix 接口，LHandIKForceEnable 可直接读取该分类输出）
WeaponPoseFix               = WeaponPoseFix or {}
WeaponPoseFix.active_weapon = WeaponPoseFix.active_weapon or {}

------------------------------------------------------
-- 角色定义
------------------------------------------------------
local characters = {
    {
        name    = "Grace",
        go_name = "cp_A100",
        enabled = true,
        joints  = {
            { name = "R_Wep",
              off_x = 0.0, off_y = 0.0, off_z = 0.0,
              off_rx = 0.0, off_ry = 0.0, off_rz = 0.0,
              _joint = nil, _cur_pos = nil, _cur_rot = nil,
              _last_anim = nil, _last_target = nil,
              _last_anim_rot = nil, _last_target_rot = nil },
            { name = "L_Wep",
              off_x = 0.0, off_y = 0.0, off_z = 0.0,
              off_rx = 0.0, off_ry = 0.0, off_rz = 0.0,
              _joint = nil, _cur_pos = nil, _cur_rot = nil,
              _last_anim = nil, _last_target = nil,
              _last_anim_rot = nil, _last_target_rot = nil },
        },
        flashlight = {
            _joint       = nil,
            status       = "Waiting...",
            x            = 0.0,
            y            = 0.0,
            z            = 0.0
        },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
        },
        _transform          = nil,
        _go_ref             = nil,
        _weapon_check_time  = -999,
        _detected_weapon    = nil,
        status              = "Waiting...",
        write_count         = 0,
        config_source       = "default",
    },
    {
        name    = "Leon",
        go_name = "cp_A000",
        enabled = true,
        joints  = {
            { name = "R_Wep",
              off_x = 0.0, off_y = 0.0, off_z = 0.0,
              off_rx = 0.0, off_ry = 0.0, off_rz = 0.0,
              _joint = nil, _cur_pos = nil, _cur_rot = nil,
              _last_anim = nil, _last_target = nil,
              _last_anim_rot = nil, _last_target_rot = nil },
            { name = "L_Wep",
              off_x = 0.0, off_y = 0.0, off_z = 0.0,
              off_rx = 0.0, off_ry = 0.0, off_rz = 0.0,
              _joint = nil, _cur_pos = nil, _cur_rot = nil,
              _last_anim = nil, _last_target = nil,
              _last_anim_rot = nil, _last_target_rot = nil },
        },
        flashlight = {
            _joint       = nil,
            status       = "Waiting...",
            x            = 0.0,
            y            = 0.0,
            z            = 0.0
        },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm01", label = "Shotgun" },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
            { prefix = "arm06", label = "Sniper"  },
        },
        _transform          = nil,
        _go_ref             = nil,
        _weapon_check_time  = -999,
        _detected_weapon    = nil,
        status              = "Waiting...",
        write_count         = 0,
        config_source       = "default",
    },
}

------------------------------------------------------
-- Config
------------------------------------------------------
local function cfg_path(char) return CONFIG_DIR .. "joint_wep_fix_" .. char.name .. ".json" end

local function save_config(char)
    local jdata = {}
    for _, j in ipairs(char.joints) do
        jdata[j.name] = { x = j.off_x, y = j.off_y, z = j.off_z, rx = j.off_rx, ry = j.off_ry, rz = j.off_rz }
    end
    local fl = char.flashlight
    json.dump_file(cfg_path(char), {
        enabled    = char.enabled,
        joints     = jdata,
        flashlight = { x = fl.x, y = fl.y, z = fl.z },
    })
    char.config_source = cfg_path(char)
end

local function load_config(char)
    local data = json.load_file(cfg_path(char))
    if data then
        if data.enabled ~= nil then char.enabled = data.enabled end
        if data.joints then
            for _, j in ipairs(char.joints) do
                local d = data.joints[j.name]
                if d then
                    j.off_x = d.x or j.off_x
                    j.off_y = d.y or j.off_y
                    j.off_z = d.z or j.off_z
                    j.off_rx = d.rx or j.off_rx
                    j.off_ry = d.ry or j.off_ry
                    j.off_rz = d.rz or j.off_rz
                end
            end
        end
        if data.flashlight then
            local fl = char.flashlight
            fl.x = data.flashlight.x or fl.x
            fl.y = data.flashlight.y or fl.y
            fl.z = data.flashlight.z or fl.z
        end
        char.config_source = cfg_path(char)
    else
        char.config_source = "default (no file)"
    end
end
for _, char in ipairs(characters) do load_config(char) end

------------------------------------------------------
-- Math helpers
------------------------------------------------------
local function rotate_vec_by_quat(v, q)
    local ux = q.x; local uy = q.y; local uz = q.z; local qw = q.w
    local tx = 2.0 * (uy * v.z - uz * v.y)
    local ty = 2.0 * (uz * v.x - ux * v.z)
    local tz = 2.0 * (ux * v.y - uy * v.x)
    return {
        x = v.x + qw * tx + (uy * tz - uz * ty),
        y = v.y + qw * ty + (uz * tx - ux * tz),
        z = v.z + qw * tz + (ux * ty - uy * tx)
    }
end

local function quat_inv(q)
    return { x = -q.x, y = -q.y, z = -q.z, w = q.w }
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

local function quat_mul(a, b)
    return {
        x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
        y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
        z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
        w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,
    }
end

------------------------------------------------------
-- Scene / Transform helpers
------------------------------------------------------
local function get_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    local scene = nil
    pcall(function() scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene") end)
    return scene
end

local function ensure_transform(char)
    if char._go_ref then
        local ok = pcall(function() char._go_ref:call("get_Name") end)
        if not ok then
            char._go_ref = nil; char._transform = nil
            for _, j in ipairs(char.joints) do j._joint = nil end
        end
    end
    if char._transform then return char._transform end

    local scene = get_scene()
    if not scene then return nil end
    local go = nil
    pcall(function() go = scene:call("findGameObject(System.String)", char.go_name) end)
    if not go then return nil end

    char._go_ref = go
    local t = nil; pcall(function() t = go:call("get_Transform") end)
    char._transform = t
    return t
end

local function joint_ok(j_obj)
    if not j_obj then return false end
    return pcall(function() j_obj:call("get_Position") end)
end

local function ensure_joints(char)
    local t = char._transform
    if not t then return end
    for _, j in ipairs(char.joints) do
        if not joint_ok(j._joint) then
            j._joint = nil
            local found = nil; pcall(function() found = t:call("getJointByName", j.name) end)
            if found then j._joint = found end
        end
    end
end

local function find_flashlight_joint(char)
    local fl = char.flashlight
    fl._joint = nil; fl.status  = "Searching..."
    local scene = get_scene()
    if not scene then return end
    local char_go = nil; pcall(function() char_go = scene:call("findGameObject(System.String)", char.go_name) end)
    if not char_go then return end
    local char_t = nil; pcall(function() char_t = char_go:call("get_Transform") end)
    if not char_t then return end
    
    local child = nil; pcall(function() child = char_t:call("get_Child") end)
    while child do
        local go = nil; pcall(function() go = child:call("get_GameObject") end)
        if go then
            local name = ""; pcall(function() name = go:call("get_Name") end)
            if name == "PlayerFlashLightController" then
                local inner = nil; pcall(function() inner = child:call("get_Child") end)
                while inner do
                    local inner_go = nil; pcall(function() inner_go = inner:call("get_GameObject") end)
                    if inner_go then
                        local inner_name = ""; pcall(function() inner_name = inner_go:call("get_Name") end)
                        if inner_name == "HandLight" then
                            local comps = inner_go:call("get_Components")
                            if comps then
                                local count = comps:call("get_Count")
                                for i = 0, count - 1 do
                                    pcall(function()
                                        local comp = comps:call("get_Item", i)
                                        if not comp then return end
                                        local td = comp:get_type_definition()
                                        if td:get_full_name() == "app.WeaponReleaseFromHand" then
                                            for _, field in ipairs(td:get_fields()) do
                                                local ok_n, fn = pcall(function() return field:get_name() end)
                                                if ok_n and fn == "_RootJoint" then
                                                    local ok_v, fv = pcall(function() return field:get_data(comp) end)
                                                    if ok_v and fv then
                                                        fl._joint = fv; fl.status = "Joint found"
                                                    end
                                                end
                                            end
                                        end
                                    end)
                                end
                            end
                            break
                        end
                    end
                    local ok_n, nxt = pcall(function() return inner:call("get_Next") end)
                    if not ok_n or not nxt then break end
                    inner = nxt
                end
                break
            end
        end
        local ok_n, nxt = pcall(function() return child:call("get_Next") end)
        if not ok_n or not nxt then break end
        child = nxt
    end
    if not fl._joint then fl.status = "Joint not found" end
end

local function update_weapon(char)
    if os.clock() - char._weapon_check_time < WEAPON_INTERVAL then return end
    char._weapon_check_time = os.clock()

    local t = char._transform
    if not t then return end

    local detected = nil
    local ok, child = pcall(function() return t:call("get_Child") end)
    if ok and child then
        while child do
            local go_ok, cgo = pcall(function() return child:call("get_GameObject") end)
            if go_ok and cgo then
                local n_ok, n = pcall(function() return cgo:call("get_Name") end)
                if n_ok and n and n:sub(1, 3) == "arm" then
                    for _, rule in ipairs(char.arm_weapon_map) do
                        if n:sub(1, #rule.prefix) == rule.prefix then
                            local draw_self = false; pcall(function() draw_self = cgo:call("get_DrawSelf") end)
                            if draw_self then
                                local pos = nil; pcall(function() pos = child:call("get_LocalPosition") end)
                                if pos 
                                   and math.abs(pos.x) < IN_HAND_THRESHOLD
                                   and math.abs(pos.y) < IN_HAND_THRESHOLD
                                   and math.abs(pos.z) < IN_HAND_THRESHOLD then
                                    detected = rule.label
                                end
                            end
                            break
                        end
                    end
                end
            end
            if detected then break end
            
            local n_ok, nx = pcall(function() return child:call("get_Next") end)
            if not n_ok or not nx then break end
            child = nx
        end
    end

    char._detected_weapon = detected
    -- 将当前的武器输出到全局，让外部的 IK 脚本读取！
    WeaponPoseFix.active_weapon[char.name] = detected
end

------------------------------------------------------
-- Routine Frame Event
------------------------------------------------------
re.on_frame(function()
    for _, char in ipairs(characters) do
        if char.enabled then
            ensure_transform(char)
            if char._transform then
                ensure_joints(char)
                pcall(update_weapon, char)
                for _, j in ipairs(char.joints) do
                    if joint_ok(j._joint) then
                        local cur = nil; pcall(function() cur = j._joint:call("get_LocalPosition") end)
                        if cur then j._cur_pos = cur end
                    else
                        j._joint = nil
                    end
                end


                local fl = char.flashlight
                if not joint_ok(fl._joint) then
                    fl._joint = nil
                    pcall(find_flashlight_joint, char)
                end
            else
                char.status = "Not in scene"
            end
        else
            char.status = "Disabled"
        end
    end
end)

------------------------------------------------------
-- Diagnostic: 每帧读取当前激活武器的名称、root、Body 与 R_Wep 的世界坐标关系
-- 纯诊断，不干预任何偏移逻辑
------------------------------------------------------
local function update_wep_diag(char)
    char._diag = char._diag or {}
    local d = char._diag

    -- 找激活中的武器 GameObject
    local t = char._transform
    if not t then d.wep_name = nil; return end

    local active_cgo = nil
    local active_go_name = nil
    local child = nil
    pcall(function() child = t:call("get_Child") end)
    while child do
        local cgo = nil
        pcall(function() cgo = child:call("get_GameObject") end)
        if cgo then
            local n = ""
            pcall(function() n = cgo:call("get_Name") end)
            if n and n:sub(1, 3) == "arm" then
                local draw_self = false
                pcall(function() draw_self = cgo:call("get_DrawSelf") end)
                if draw_self then
                    active_cgo = cgo
                    active_go_name = n
                    break
                end
            end
        end
        local ok, nxt = pcall(function() return child:call("get_Next") end)
        if not ok or not nxt then break end
        child = nxt
    end

    d.wep_name = active_go_name  -- e.g. "arm0007"

    if not active_cgo then
        d.root_pos = nil; d.body_pos = nil
        return
    end

    local wep_t = nil
    pcall(function() wep_t = active_cgo:call("get_Transform") end)
    if not wep_t then d.root_pos = nil; d.body_pos = nil; return end

    -- root 骨骼
    local root_j = nil
    pcall(function() root_j = wep_t:call("getJointByName", "root") end)
    if root_j then
        pcall(function() d.root_pos = root_j:call("get_Position") end)
    else
        d.root_pos = nil
    end
    d.has_root = (root_j ~= nil)

    -- Body 骨骼
    local body_j = nil
    pcall(function() body_j = wep_t:call("getJointByName", "Body") end)
    if body_j then
        pcall(function() d.body_pos = body_j:call("get_Position") end)
    else
        d.body_pos = nil
    end
    d.has_body = (body_j ~= nil)

    -- R_Wep 世界坐标
    local r_wep_world = nil
    for _, j in ipairs(char.joints) do
        if j.name == "R_Wep" and joint_ok(j._joint) then
            pcall(function() r_wep_world = j._joint:call("get_Position") end)
            break
        end
    end
    d.r_wep_world = r_wep_world

    -- R_Arm_Hand 世界坐标（从角色骨架上读取）
    local r_arm_hand_j = nil
    pcall(function() r_arm_hand_j = t:call("getJointByName", "R_Arm_Hand") end)
    if r_arm_hand_j then
        pcall(function() d.r_arm_hand_pos = r_arm_hand_j:call("get_Position") end)
    else
        d.r_arm_hand_pos = nil
    end
    d.has_r_arm_hand = (r_arm_hand_j ~= nil)

    -- 距离计算
    local function dist3(a, b)
        if not a or not b then return nil end
        local dx = a.x - b.x
        local dy = a.y - b.y
        local dz = a.z - b.z
        return math.sqrt(dx*dx + dy*dy + dz*dz)
    end

    d.dist_root       = dist3(r_wep_world,       d.root_pos)
    d.dist_body       = dist3(r_wep_world,       d.body_pos)
    d.dist_hand_rwep  = dist3(d.r_arm_hand_pos,  r_wep_world)
    d.dist_hand_root  = dist3(d.r_arm_hand_pos,  d.root_pos)
    d.dist_hand_body  = dist3(d.r_arm_hand_pos,  d.body_pos)
end

re.on_frame(function()
    for _, char in ipairs(characters) do
        if char.enabled then
            ensure_transform(char)
            if char._transform then
                ensure_joints(char)
                pcall(update_weapon, char)
                pcall(update_wep_diag, char)
                for _, j in ipairs(char.joints) do
                    if joint_ok(j._joint) then
                        local cur = nil; pcall(function() cur = j._joint:call("get_LocalPosition") end)
                        if cur then j._cur_pos = cur end
                    else
                        j._joint = nil
                    end
                end
                local fl = char.flashlight
                if not joint_ok(fl._joint) then
                    fl._joint = nil
                    pcall(find_flashlight_joint, char)
                end
            else
                char.status = "Not in scene"
            end
        else
            char.status = "Disabled"
        end
    end
end)

------------------------------------------------------
-- LateUpdateBehavior (Pre)
-- 尝试更换钩子时机，提前介入骨骼系统，观察能否被引擎内部过滤杠杆抖动
------------------------------------------------------
re.on_pre_application_entry("LateUpdateBehavior", function()
    for _, char in ipairs(characters) do
        if char.enabled and char._transform then
            local written = false

            for _, j in ipairs(char.joints) do
                if joint_ok(j._joint) then
                    local cur_pos = nil
                    local cur_rot = nil
                    pcall(function()
                        cur_pos = j._joint:call("get_LocalPosition")
                        cur_rot = j._joint:call("get_LocalRotation")
                    end)

                    if cur_pos and cur_rot then
                        local NEAR = 0.0001
                        local anim_pos, anim_rot
                        
                        -- Position diff tracking
                        if j._last_target and
                           math.abs(cur_pos.x - j._last_target.x) < NEAR and
                           math.abs(cur_pos.y - j._last_target.y) < NEAR and
                           math.abs(cur_pos.z - j._last_target.z) < NEAR then
                            anim_pos = j._last_anim
                        else
                            anim_pos = { x = cur_pos.x, y = cur_pos.y, z = cur_pos.z }
                        end

                        -- Rotation diff tracking
                        if j._last_target_rot and
                           math.abs(cur_rot.x - j._last_target_rot.x) < NEAR and
                           math.abs(cur_rot.y - j._last_target_rot.y) < NEAR and
                           math.abs(cur_rot.z - j._last_target_rot.z) < NEAR and
                           math.abs(cur_rot.w - j._last_target_rot.w) < NEAR then
                            anim_rot = j._last_anim_rot
                        else
                            anim_rot = { x=cur_rot.x, y=cur_rot.y, z=cur_rot.z, w=cur_rot.w }
                        end

                        -- Compute new targets
                        -- 恢复：直接应用父节点空间的坐标偏移
                        local tx = anim_pos.x + j.off_x
                        local ty = anim_pos.y + j.off_y
                        local tz = anim_pos.z + j.off_z

                        local q_off = euler_to_quat(math.rad(j.off_rx), math.rad(j.off_ry), math.rad(j.off_rz))
                        local q_target = quat_mul(anim_rot, q_off)

                        -- Write to joint
                        pcall(function()
                            if math.abs(tx - cur_pos.x) > 1e-5 or math.abs(ty - cur_pos.y) > 1e-5 or math.abs(tz - cur_pos.z) > 1e-5 then
                                j._joint:call("set_LocalPosition", Vector3f.new(tx, ty, tz))
                                written = true
                            end

                            if math.abs(q_target.x - cur_rot.x) > 1e-5 or
                               math.abs(q_target.y - cur_rot.y) > 1e-5 or
                               math.abs(q_target.z - cur_rot.z) > 1e-5 or
                               math.abs(q_target.w - cur_rot.w) > 1e-5 then
                                local v_rot = j._joint:call("get_LocalRotation") 
                                v_rot.x, v_rot.y, v_rot.z, v_rot.w = q_target.x, q_target.y, q_target.z, q_target.w
                                j._joint:call("set_LocalRotation", v_rot)
                                written = true
                            end
                        end)

                        -- Update tracking records
                        j._last_anim       = anim_pos
                        j._last_target     = { x = tx, y = ty, z = tz }
                        j._cur_pos         = cur_pos
                        
                        j._last_anim_rot   = anim_rot
                        j._last_target_rot = q_target
                        j._cur_rot         = cur_rot
                    end
                else
                    j._joint = nil
                end
            end

            -- 手电筒
            local fl = char.flashlight
            if joint_ok(fl._joint) then
                local l_wep = nil
                for _, j in ipairs(char.joints) do
                    if j.name == "L_Wep" then l_wep = j._joint; break end
                end
                if joint_ok(l_wep) then
                    local wpos, wrot = nil, nil
                    pcall(function() wpos = l_wep:call("get_Position"); wrot = l_wep:call("get_Rotation") end)
                    if wpos and wrot then
                        local ok = pcall(function()
                            fl._joint:call("set_Position", wpos)
                            fl._joint:call("set_Rotation", wrot)
                        end)
                        if ok then fl.status = "Anchored to L_Wep"; written = true
                        else fl.status = "Failed to parent" end
                    end
                else fl.status = "Waiting for L_Wep..." end
            else
                fl._joint = nil
            end

            if written then char.write_count = char.write_count + 1 end
            char.status = string.format("Active | weapon: %s | writes: %d",
                char._detected_weapon or "None", char.write_count)
        end
    end
end)

------------------------------------------------------
-- UI
------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.collapsing_header("Wep Joint Fix") then return end

    for _, char in ipairs(characters) do
        imgui.push_id("wjf_" .. char.name)
        if imgui.tree_node(char.name .. " (" .. char.go_name .. ")") then

            local ch, ne = imgui.checkbox("Enabled", char.enabled)
            if ch then char.enabled = ne end

            imgui.text("Status : " .. char.status)
            imgui.text("Config : " .. char.config_source)
            imgui.separator()

            for _, j in ipairs(char.joints) do
                imgui.push_id("j_" .. j.name)
                local joint_status = joint_ok(j._joint) and "  [OK]" or "  [NOT FOUND]"
                imgui.text(j.name .. joint_status)

                if j._cur_pos then
                    imgui.text(string.format("  Pos : (%.4f, %.4f, %.4f)", j._cur_pos.x, j._cur_pos.y, j._cur_pos.z))
                end
                if j._cur_rot then
                    imgui.text(string.format("  RotQ: (%.2f, %.2f, %.2f, %.2f)", j._cur_rot.x, j._cur_rot.y, j._cur_rot.z, j._cur_rot.w))
                end

                local cx, vx = imgui.drag_float("Pos X##" .. j.name, j.off_x, 0.0001, -0.5, 0.5, "%.4f")
                if cx then j.off_x = vx end
                local cy, vy = imgui.drag_float("Pos Y##" .. j.name, j.off_y, 0.0001, -0.5, 0.5, "%.4f")
                if cy then j.off_y = vy end
                local cz, vz = imgui.drag_float("Pos Z##" .. j.name, j.off_z, 0.0001, -0.5, 0.5, "%.4f")
                if cz then j.off_z = vz end

                local rx, vrx = imgui.drag_float("Rot X##" .. j.name, j.off_rx, 0.1, -180.0, 180.0, "%.1f")
                if rx then j.off_rx = vrx end
                local ry, vry = imgui.drag_float("Rot Y##" .. j.name, j.off_ry, 0.1, -180.0, 180.0, "%.1f")
                if ry then j.off_ry = vry end
                local rz, vrz = imgui.drag_float("Rot Z##" .. j.name, j.off_rz, 0.1, -180.0, 180.0, "%.1f")
                if rz then j.off_rz = vrz end

                if imgui.button("Reset##" .. j.name) then 
                    j.off_x, j.off_y, j.off_z = 0.0, 0.0, 0.0 
                    j.off_rx, j.off_ry, j.off_rz = 0.0, 0.0, 0.0
                end
                imgui.spacing()
                imgui.pop_id()
            end

            imgui.separator()
            imgui.text("Flashlight (HandLight._RootJoint):")
            imgui.text("  Status: " .. char.flashlight.status)
            imgui.spacing()

            local fl = char.flashlight
            local fx, fvx = imgui.drag_float("Flashlight X", fl.x, 0.0001, -0.5, 0.5, "%.4f")
            if fx then fl.x = fvx end
            local fy, fvy = imgui.drag_float("Flashlight Y", fl.y, 0.0001, -0.5, 0.5, "%.4f")
            if fy then fl.y = fvy end
            local fz, fvz = imgui.drag_float("Flashlight Z", fl.z, 0.0001, -0.5, 0.5, "%.4f")
            if fz then fl.z = fvz end

            imgui.separator()
            if imgui.button("Save##" .. char.name) then save_config(char) end
            imgui.same_line()
            if imgui.button("Reload##" .. char.name) then load_config(char) end

            imgui.tree_pop()
        end
        imgui.pop_id()
    end
end)

log.info("[WepJointFix] Loaded.")
