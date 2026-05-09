-- cg_weapon_snap.lua
-- CG武器吸附右手脚本
-- 策略：钩子负责标记"过场状态"，轮询负责扫场景，完全解耦

local TARGET_CHARS = {"cp_A000", "ch0100", "cp_A100", "ch0200", "ch01", "ch02", 
                        "cp_A110", "cp_E900", "ch0250" ,"cp_E800",}
local SNAP_THRESHOLD = 0.057
local RIGHT_HAND_BIAS = 0.073
local ENABLED = true
local EXTRA_ITEMS = {
    -- { "物品名", "骨骼名", "目标角色" },
    -- { "物品名", "骨骼名" },
    -- { "物品名" },

    { "sm87_114_00_00", "_00" },
    { "sm87_155_00", "Handle" },
    { "sm87_152_00_00", "_00" },
    { "sm87_121_00_01", "_00" },
    { "sm87_121_00_00", "_00" },
    { "sm87_179_00_03", "_01", "Grace" },
    { "sm87_080_00_00", "_00" },

}

local NATIVE_OFFSETS = {
    Leon = {
        R = { x = -0.083582, y = 0.045764, z = -0.020972 },
        L = { x = 0.085042, y = -0.038108, z = -0.003032 }
    },
    Grace = {
        R = { x = -0.065931, y = 0.029980, z = -0.018046 },
        L = { x = 0.066719, y = -0.025212, z = 0.026158 }
    }
}

local cached_weapons = {}
local cached_chars = {}
local in_cutscene = false
local last_scan_time = 0
local has_scanned_this_cutscene = false
local cutscene_start_time = 0      -- in_cutscene 第一次变 true 的时间

local ACTIVATION_DELAY = 0.0       -- 进入 CG 后等待 N 秒再开始操作
local DEACTIVATION_DELAY = 1.5    -- CG 结束后持续吸附 N 秒
local LAYER_CG_PERSIST = 0.3       -- LayerCG 持续超过此秒数才认定为 CG

local layer_cg_true_since = 0      -- LayerCG 开始为 true 的时间
local layer_cg_was_true = false    -- 上一帧 LayerCG 是否为 true
local cutscene_end_time = 0        -- CG 真正结束的时间

local cached_json = {}
local last_json_read_time = 0

local SKEL_REST = {
    Leon = {
        R_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","R_Arm_Clavicle","R_Arm_Upper","R_Arm_Lower","R_Arm_Hand","R_Wep"},
        L_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","L_Arm_Clavicle","L_Arm_Upper","L_Arm_Lower","L_Arm_Hand","L_Wep"},
        bones = {
            root           = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {0.707107, 0.0, 0.0, 0.707107} },
            Hip            = { local_offset = {0.0, 0.966725, -0.002509}, local_rest_rot = {0.0, -0.0, 0.707107, 0.707107} },
            Spine_0        = { local_offset = {-0.0, 0.0, -0.0}, local_rest_rot = {0.0, -0.034676, 0.0, 0.999399} },
            Spine_1        = { local_offset = {0.179877, 0.0, -0.0}, local_rest_rot = {0.0, 0.102253, 0.0, 0.994758} },
            Spine_2        = { local_offset = {0.179681, 0.0, -0.0}, local_rest_rot = {0.0, -0.05355, 0.0, 0.998565} },
            R_Arm_Clavicle = { local_offset = {0.127308, 0.021975, 0.047392}, local_rest_rot = {0.730962, -0.661948, 0.132101, 0.100346} },
            R_Arm_Upper    = { local_offset = {-0.182025, 1e-06, 1e-06}, local_rest_rot = {0.092047, -0.097451, -0.399319, 0.906959} },
            R_Arm_Lower    = { local_offset = {-0.274661, -0.0, 0.0}, local_rest_rot = {0.0, -0.566439, 0.0, 0.824104} },
            R_Arm_Hand     = { local_offset = {-0.258919, -0.0, -0.0}, local_rest_rot = {-0.0, -0.0, 0.0, 1.0} },
            R_Wep          = { local_offset = {-0.083582, 0.045764, -0.020972}, local_rest_rot = {-0.0, -0.0, -0.0, 1.0} },
            L_Arm_Clavicle = { local_offset = {0.127308, -0.021975, 0.047392}, local_rest_rot = {0.132104, 0.100349, -0.730961, 0.661948} },
            L_Arm_Upper    = { local_offset = {0.18202, 0.0, 0.0}, local_rest_rot = {0.092051, -0.097456, -0.399311, 0.906962} },
            L_Arm_Lower    = { local_offset = {0.274661, -0.0, 0.0}, local_rest_rot = {1e-06, -0.566439, 1e-06, 0.824104} },
            L_Arm_Hand     = { local_offset = {0.258919, -0.0, -0.0}, local_rest_rot = {-0.0, -0.0, -0.0, 1.0} },
            L_Wep          = { local_offset = {0.083582, -0.045764, 0.020972}, local_rest_rot = {0.0, 0.0, 0.0, 1.0} }
        }
    },
    Grace = {
        R_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","R_Arm_Clavicle","R_Arm_Upper","R_Arm_Lower","R_Arm_Hand","R_Wep"},
        L_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","L_Arm_Clavicle","L_Arm_Upper","L_Arm_Lower","L_Arm_Hand","L_Wep"},
        bones = {
            root           = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {0.707107, 0.0, 0.0, 0.707107} },
            Hip            = { local_offset = {0.0, 0.948953, -0.010371}, local_rest_rot = {0.0, -0.0, 0.707107, 0.707107} },
            Spine_0        = { local_offset = {-0.0, 0.0, 0.0}, local_rest_rot = {0.0, -0.161014, 0.0, 0.986952} },
            Spine_1        = { local_offset = {0.148353, 0.0, 0.0}, local_rest_rot = {0.0, 0.203038, 0.0, 0.979171} },
            Spine_2        = { local_offset = {0.172928, 0.0, -0.0}, local_rest_rot = {0.0, 0.072154, 0.0, 0.997394} },
            R_Arm_Clavicle = { local_offset = {0.103962, 0.039615, 0.035842}, local_rest_rot = {0.714357, -0.651024, 0.247539, 0.067724} },
            R_Arm_Upper    = { local_offset = {-0.123271, 0.0, -0.0}, local_rest_rot = {0.054696, -0.218107, -0.426008, 0.876331} },
            R_Arm_Lower    = { local_offset = {-0.283373, -0.0, -0.0}, local_rest_rot = {0.0, -0.310391, 0.0, 0.950609} },
            R_Arm_Hand     = { local_offset = {-0.235196, 0.0, -0.0}, local_rest_rot = {0.108369, -0.0, -1e-06, 0.994111} },
            R_Wep          = { local_offset = {-0.065931, 0.029980, -0.018046}, local_rest_rot = {-2.9e-05, 2e-06, 1.1e-05, 1.0} },
            L_Arm_Clavicle = { local_offset = {0.103962, -0.039615, 0.035842}, local_rest_rot = {0.247539, 0.067724, -0.714357, 0.651024} },
            L_Arm_Upper    = { local_offset = {0.123271, -0.0, 0.0}, local_rest_rot = {0.054696, -0.218107, -0.426008, 0.87633} },
            L_Arm_Lower    = { local_offset = {0.283374, 0.0, -0.0}, local_rest_rot = {0.0, -0.310391, 0.0, 0.950609} },
            L_Arm_Hand     = { local_offset = {0.235196, -0.0, -0.0}, local_rest_rot = {0.108369, -0.0, -1e-06, 0.994111} },
            L_Wep          = { local_offset = {0.065931, -0.029980, 0.018046}, local_rest_rot = {-2.9e-05, 2e-06, 1.1e-05, 1.0} }
        }
    }
}

local last_first_transform = nil
local transform_stable_frames = 0
local in_transition = false
local STABILITY_THRESHOLD = 5

-- ══════════════════════════════════════════════════════════════════
-- 性能优化：缓存 sdk 类型查找结果（避免每帧重复查找）
-- ══════════════════════════════════════════════════════════════════
local type_SceneManager = sdk.find_type_definition("via.SceneManager")
local typeof_Motion = sdk.typeof("via.motion.Motion")

-- ══════════════════════════════════════════════════════════════════
-- 性能优化：sc() 无闭包版本 —— 直接传函数引用给 pcall
-- ══════════════════════════════════════════════════════════════════
local function sc(obj, method, ...)
    if not obj then return nil end
    local ok, r = pcall(obj.call, obj, method, ...)
    return ok and r or nil
end

-- ══════════════════════════════════════════════════════════════════
-- 性能优化：可复用临时 table 池（避免热循环中大量 {x=,y=,z=} 分配）
-- ══════════════════════════════════════════════════════════════════
local _vec_pool = {}
local _vec_pool_idx = 0

local function vec_pool_reset()
    _vec_pool_idx = 0
end

local function vec3(x, y, z)
    _vec_pool_idx = _vec_pool_idx + 1
    local v = _vec_pool[_vec_pool_idx]
    if not v then
        v = { x = x, y = y, z = z }
        _vec_pool[_vec_pool_idx] = v
    else
        v.x, v.y, v.z = x, y, z
    end
    return v
end

local function vec4(x, y, z, w)
    _vec_pool_idx = _vec_pool_idx + 1
    local v = _vec_pool[_vec_pool_idx]
    if not v then
        v = { x = x, y = y, z = z, w = w }
        _vec_pool[_vec_pool_idx] = v
    else
        v.x, v.y, v.z, v.w = x, y, z, w
    end
    return v
end

local function quat_mul_vec(q, v)
    local qvx, qvy, qvz = q.x, q.y, q.z
    local vx, vy, vz = v.x, v.y, v.z
    local uvx = qvy * vz - qvz * vy
    local uvy = qvz * vx - qvx * vz
    local uvz = qvx * vy - qvy * vx
    local uuvx = qvy * uvz - qvz * uvy
    local uuvy = qvz * uvx - qvx * uvz
    local uuvz = qvx * uvy - qvy * uvx
    local w2 = q.w * 2.0
    return vec3(vx + (uvx * w2 + uuvx * 2.0), vy + (uvy * w2 + uuvy * 2.0), vz + (uvz * w2 + uuvz * 2.0))
end

local function closest_point_on_segment(p, a, b)
    local abx, aby, abz = b.x-a.x, b.y-a.y, b.z-a.z
    local apx, apy, apz = p.x-a.x, p.y-a.y, p.z-a.z
    local len2 = abx*abx + aby*aby + abz*abz
    local t = len2 > 1e-10 and math.max(0, math.min(1, (apx*abx+apy*aby+apz*abz)/len2)) or 0
    local cpx, cpy, cpz = a.x+t*abx, a.y+t*aby, a.z+t*abz
    local dx, dy, dz = p.x-cpx, p.y-cpy, p.z-cpz
    return vec3(cpx, cpy, cpz), math.sqrt(dx*dx+dy*dy+dz*dz)
end

-- ══════════════════════════════════════════════════════════════════
-- 性能优化：缓存角色名 -> mapped_name 映射（避免每帧重复字符串匹配）
-- ══════════════════════════════════════════════════════════════════
local _char_mapped_name_cache = {}

local function get_mapped_name(char_name)
    local cached = _char_mapped_name_cache[char_name]
    if cached then return cached end
    local lower_name = char_name:lower()
    local mapped = "Leon"
    if lower_name:find("cp_a100") or lower_name:find("ch0200") or lower_name:find("ch02") or lower_name:find("cp_a110") or lower_name:find("cp_e900") or lower_name:find("ch0250") then
        mapped = "Grace"
    end
    _char_mapped_name_cache[char_name] = mapped
    return mapped
end

local function get_joint_offset(char_name, wep_joint_name)
    local mapped_name = get_mapped_name(char_name)

    local t = os.clock()
    if t - last_json_read_time > 1.0 then
        cached_json["Leon"] = json.load_file("WepJointFix/joint_wep_fix_Leon.json") or {}
        cached_json["Grace"] = json.load_file("WepJointFix/joint_wep_fix_Grace.json") or {}
        last_json_read_time = t
    end
    local data = cached_json[mapped_name]
    if data and data.joints then
        if type(data.joints) == "table" and data.joints[1] then
            for _, j in ipairs(data.joints) do
                if j.name == wep_joint_name then
                    return vec3(j.off_x or 0, j.off_y or 0, j.off_z or 0)
                end
            end
        else
            local r = data.joints[wep_joint_name]
            if r then return vec3(r.x or r.off_x or 0, r.y or r.off_y or 0, r.z or r.off_z or 0) end
        end
    end
    return vec3(0, 0, 0)
end

local function is_attached_to_char(t)
    local cur = t
    for _ = 1, 10 do
        local p = sc(cur, "get_Parent")
        if not p then break end
        local pgo = sc(p, "get_GameObject")
        if pgo then
            local pn = tostring(sc(pgo, "get_Name") or ""):lower()
            if pn:find("cp_a") or pn:find("ch01") or pn:find("ch02") or pn:find("ch10") or pn:find("pl") then return true end
        end
        cur = p
    end
    return false
end

-- 真正的可见性检测：同时检查自身和直接父容器的 Valid (Enabled) 和 DrawSelf
local function check_visible_with_parent(t, go)
    if not go then return false end
    -- 合并 pcall：一次调用检查自身 + 父级
    local ok, result = pcall(function()
        local valid = go:call("get_Valid")
        local ds = go:call("get_DrawSelf")
        if not valid or not ds then return false end
        if t then
            local parent_t = t:call("get_Parent")
            if parent_t then
                local parent_go = parent_t:call("get_GameObject")
                if parent_go then
                    local p_valid = parent_go:call("get_Valid")
                    local p_ds = parent_go:call("get_DrawSelf")
                    if not p_valid or not p_ds then return false end
                end
            end
        end
        return true
    end)
    return ok and result or false
end

-- ══════════════════════════════════════════════════════════════════
-- 性能优化：check_layer_cg 合并为单个 pcall（原来 7+ 个独立 pcall）
-- ══════════════════════════════════════════════════════════════════
local function check_layer_cg(go)
    if not go then return false end
    local ok, result = pcall(function()
        local motion = go:call("getComponent(System.Type)", typeof_Motion)
        if not motion then return false end

        local layer0 = motion:call("getLayer", 0)
        if not layer0 then return false end
        local bank0 = layer0:call("get_MotionBankID")
        local mot0 = layer0:call("get_MotionID")
        
        -- 判断 Bank 0 且 MotID 大于 0 且是 100 的倍数
        if (bank0 == 0 and mot0 > 0 and (mot0 % 100 == 0)) or (bank0 == 10 and mot0 == 32) then
            return true
        end
        return false
    end)
    return ok and result == true
end

-- local function check_layer_cg(go)
--     if not go then return false end
--     local ok, result = pcall(function()
--         local motion = go:call("getComponent(System.Type)", typeof_Motion)
--         if not motion then return false end

--         local layer3 = motion:call("getLayer", 3)
--         if not layer3 then return false end
--         local bank3 = layer3:call("get_MotionBankID")
--         local mot3 = layer3:call("get_MotionID")
--         if not (bank3 == 0 and mot3 ~= nil and mot3 >= 2147483647) then return false end

--         local layer0 = motion:call("getLayer", 0)
--         if layer0 then
--             local bank0 = layer0:call("get_MotionBankID")
--             local mot0 = layer0:call("get_MotionID")
--             if (bank0 == 0 and (mot0 == nil or mot0 == 0 or mot0 == 8 or mot0 == 10)) or bank0 == 500 then
--                 return false
--             end
--         end
--         return true
--     end)
--     return ok and result or false
-- end

local PLAYER_CHARS = {"cp_A000", "cp_A100", "cp_A110", "cp_E900"}

-- ══════════════════════════════════════════════════════════════════
-- 性能优化：缓存 findGameObject 结果（避免每帧 4 次引擎遍历）
-- ══════════════════════════════════════════════════════════════════
local _cached_player_gos = {}       -- pname -> { go=go, valid_until=time }
local _player_go_cache_ttl = 0.5    -- 缓存生存时间（秒）

local function get_player_go(scene, pname, now)
    local entry = _cached_player_gos[pname]
    
    if entry and now < entry.valid_until then
        -- 缓存命中，且未过期
        local go = entry.go
        if go then
            local ok, valid = pcall(go.call, go, "get_Valid")
            if ok and valid then return go end
            -- 如果缓存的物体突然无效了，让它强行过期，重新查找
            entry.valid_until = 0 
        else
            -- 缓存命中，且明确记录了该物体【不存在】（go == nil）
            -- 直接返回 nil，不要每帧都去 findGameObject！
            return nil
        end
    end

    local ok, go = pcall(scene.call, scene, "findGameObject(System.String)", pname)
    if not ok then go = nil end
    
    if not entry then
        entry = { go = go, valid_until = now + _player_go_cache_ttl }
        _cached_player_gos[pname] = entry
    else
        entry.go = go
        entry.valid_until = now + _player_go_cache_ttl
    end
    return go
end

local function check_if_in_cg(scene, now)
    local player_found = false
    local any_player_visible = false

    for _, pname in ipairs(PLAYER_CHARS) do
        local go = get_player_go(scene, pname, now)
        if go then
            player_found = true
            local ok, visible = pcall(go.call, go, "get_DrawSelf")
            if not ok then visible = false end

            if visible then
                any_player_visible = true
                if check_layer_cg(go) then return true end
            end
        end
    end

    if not player_found or not any_player_visible then
        return true
    end

    return false
end

-- ══════════════════════════════════════════════════════════════════
-- 性能优化：缓存 hand_key 字符串（避免热循环中每帧字符串拼接）
-- ══════════════════════════════════════════════════════════════════
local _hand_key_cache = {}

local function get_hand_key(char_name, joint_name)
    local outer = _hand_key_cache[char_name]
    if not outer then
        outer = {}
        _hand_key_cache[char_name] = outer
    end
    local key = outer[joint_name]
    if not key then
        key = char_name .. ":" .. joint_name
        outer[joint_name] = key
    end
    return key
end

local function scan_scene_objects(t, depth)
    local cur = t
    while cur do
        if depth > 100 then return end
        local go = sc(cur, "get_GameObject")
        if go then
            local name = tostring(sc(go, "get_Name") or "")
            local lower_name = name:lower()

            local is_char = false
            for _, cname in ipairs(TARGET_CHARS) do
                if name:find(cname) then is_char = true; break end
            end

            if is_char then
                local found = false
                for _, c in ipairs(cached_chars) do if c.transform == cur then found = true; break end end
                if not found then
                    local j_rhand = sc(cur, "getJointByName", "R_Arm_Hand")
                    local j_lhand = sc(cur, "getJointByName", "L_Arm_Hand")
                    local j_rwep  = sc(cur, "getJointByName", "R_Wep")
                    local j_lwep  = sc(cur, "getJointByName", "L_Wep")
                    if j_rhand or j_lhand then
                        local char_entry = {
                            name = name, go = go, transform = cur,
                            r_hand_joint = j_rhand, l_hand_joint = j_lhand,
                            r_wep_joint = j_rwep, l_wep_joint = j_lwep,
                            mapped_name = get_mapped_name(name)
                        }
                        
                        local R_CHAIN = {"root","Hip","Spine_0","Spine_1","Spine_2", "R_Arm_Clavicle","R_Arm_Upper","R_Arm_Lower","R_Arm_Hand"}
                        local L_CHAIN = {"root","Hip","Spine_0","Spine_1","Spine_2", "L_Arm_Clavicle","L_Arm_Upper","L_Arm_Lower","L_Arm_Hand"}
                        char_entry.r_fk_joints = {}
                        char_entry.l_fk_joints = {}
                        for _, bname in ipairs(R_CHAIN) do
                            local j = sc(cur, "getJointByName", bname)
                            if not j and bname == "root" then j = cur end
                            char_entry.r_fk_joints[bname] = j
                        end
                        for _, bname in ipairs(L_CHAIN) do
                            local j = sc(cur, "getJointByName", bname)
                            if not j and bname == "root" then j = cur end
                            char_entry.l_fk_joints[bname] = j
                        end
                        
                        table.insert(cached_chars, char_entry)
                    end
                end
            end

            local is_extra = false
            local extra_joint_name = nil
            local exclusive_char = nil
            for _, item in ipairs(EXTRA_ITEMS) do
                if name:find(item[1]) then
                    is_extra = true
                    extra_joint_name = item[2]
                    exclusive_char = item[3]
                    break
                end
            end

            local is_wep = lower_name:sub(1, 2) == "wp"
            if (is_wep or is_extra) and not is_char then
                local found = false
                for _, w in ipairs(cached_weapons) do if w.transform == cur then found = true; break end end
                if not found then
                    local w_joints = sc(cur, "get_Joints")
                    local j0 = w_joints and w_joints[0]
                    local j1 = w_joints and w_joints[1]
                    local j_muzzle = sc(cur, "getJointByName", "vfx_muzzle1")
                    local j_extra = extra_joint_name and sc(cur, "getJointByName", extra_joint_name) or nil
                    local j0_to_j1 = nil
                    local j0_to_muzzle = nil
                    if j0 and j1 and j_muzzle then
                        local p_j0  = sc(j0, "get_Position")
                        local r_j0  = sc(j0, "get_Rotation")
                        local p_j1  = sc(j1, "get_Position")
                        local p_muz = sc(j_muzzle, "get_Position")
                        if p_j0 and r_j0 and p_j1 and p_muz then
                            local inv_r = {x=-r_j0.x, y=-r_j0.y, z=-r_j0.z, w=r_j0.w}
                            -- scan 阶段不用 vec pool（只在初始化时调用一次，需要持久 table）
                            j0_to_j1     = quat_mul_vec(inv_r, vec3(p_j1.x-p_j0.x, p_j1.y-p_j0.y, p_j1.z-p_j0.z))
                            j0_to_j1     = { x = j0_to_j1.x, y = j0_to_j1.y, z = j0_to_j1.z } -- 持久化复制
                            j0_to_muzzle = quat_mul_vec(inv_r, vec3(p_muz.x-p_j0.x, p_muz.y-p_j0.y, p_muz.z-p_j0.z))
                            j0_to_muzzle = { x = j0_to_muzzle.x, y = j0_to_muzzle.y, z = j0_to_muzzle.z }
                        end
                    end
                    table.insert(cached_weapons, { name=name, go=go, transform=cur, j0=j0, j1=j1, j_muzzle=j_muzzle, j_extra=j_extra, is_extra=is_extra, exclusive_char=exclusive_char, j0_to_j1=j0_to_j1, j0_to_muzzle=j0_to_muzzle, snapped_to=nil, dist_to_hand=-1 })
                end
            end
        end
        local child = sc(cur, "get_Child")
        if child then scan_scene_objects(child, depth + 1) end
        cur = sc(cur, "get_Next")
    end
end

-- 全场景扫描（从 FirstTransform 开始遍历所有节点）
local function full_scene_scan()
    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sdk.call_native_func(sm, type_SceneManager, "get_CurrentScene")
    if scene then
        scan_scene_objects(sc(scene, "get_FirstTransform"), 0)
    end
end

-- 手动强制重扫
local function force_full_scan()
    cached_weapons = {}
    cached_chars = {}
    _char_joints_cache = {}
    _cached_player_gos = {}
    full_scene_scan()
end

-- ══════════════════════════════════════════════════════════════════
-- 预构建每个角色的关节信息表（避免热循环中每帧创建 joints table）
-- ══════════════════════════════════════════════════════════════════
local _char_joints_cache = {}   -- char.transform -> { {name, wep_j, hand_j, base_off}, ... }

local ROOT_BONES = { root = true, Hip = true }
local R_CHAIN = {"root","Hip","Spine_0","Spine_1","Spine_2", "R_Arm_Clavicle","R_Arm_Upper","R_Arm_Lower","R_Arm_Hand"}
local L_CHAIN = {"root","Hip","Spine_0","Spine_1","Spine_2", "L_Arm_Clavicle","L_Arm_Upper","L_Arm_Lower","L_Arm_Hand"}

local function fk_wep_world_pos(char, side)
    local skel = SKEL_REST[char.mapped_name]
    if not skel or not skel.bones then return nil end

    local chain  = (side == "R") and R_CHAIN or L_CHAIN
    local jcache = (side == "R") and char.r_fk_joints or char.l_fk_joints

    local prev_pos, prev_rot = nil, nil

    for _, bname in ipairs(chain) do
        local j = jcache[bname]
        if not j then return nil end

        local rot = sc(j, "get_Rotation")
        if not rot then return nil end
        local pos

        if ROOT_BONES[bname] then
            pos = sc(j, "get_Position")
            if not pos then return nil end
        else
            local b = skel.bones[bname]
            local off = b and b.local_offset
            if not off or not prev_pos or not prev_rot then return nil end
            local rotated = quat_mul_vec(prev_rot, vec3(off[1], off[2], off[3]))
            pos = vec3(prev_pos.x + rotated.x, prev_pos.y + rotated.y, prev_pos.z + rotated.z)
        end

        prev_pos, prev_rot = pos, rot
    end

    -- 通过 Hand 计算 Wep 坐标
    local wep_bname = side .. "_Wep"
    local wdata = skel.bones[wep_bname]
    if not wdata or not wdata.local_offset or not prev_pos or not prev_rot then return nil end
    local off = wdata.local_offset
    local rotated = quat_mul_vec(prev_rot, vec3(off[1], off[2], off[3]))
    return vec3(prev_pos.x + rotated.x, prev_pos.y + rotated.y, prev_pos.z + rotated.z)
end

local function get_char_joints(char)
    local entry = _char_joints_cache[char.transform]
    if entry then return entry end
    local offsets = (char.mapped_name == "Grace") and NATIVE_OFFSETS.Grace or NATIVE_OFFSETS.Leon
    entry = {
        { name = "R_Wep", wep_j = char.r_wep_joint, hand_j = char.r_hand_joint, base_off = offsets.R },
        { name = "L_Wep", wep_j = char.l_wep_joint, hand_j = char.l_hand_joint, base_off = offsets.L }
    }
    _char_joints_cache[char.transform] = entry
    return entry
end


re.on_pre_application_entry("LateUpdateBehavior", function()
    if not ENABLED then return end

    local now = os.clock()

    -- 每帧重置 vec pool
    vec_pool_reset()

    -- ── 基于动画 Layer 的 CG 检测 ──────────────────────────────────────
    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sm and sdk.call_native_func(sm, type_SceneManager, "get_CurrentScene") or nil
    local layer_cg_now = scene and check_if_in_cg(scene, now) or false

    if layer_cg_now then
        if not layer_cg_was_true then
            layer_cg_true_since = now
        end
        cutscene_end_time = 0
        if not in_cutscene and (now - layer_cg_true_since >= LAYER_CG_PERSIST) then
            in_cutscene = true
            cutscene_start_time = now
            cached_weapons = {}
            cached_chars = {}
            _char_joints_cache = {}
            has_scanned_this_cutscene = false
        end
    else
        if in_cutscene then
            if cutscene_end_time == 0 then
                cutscene_end_time = now
            end
            if now - cutscene_end_time >= DEACTIVATION_DELAY then
                in_cutscene = false
                cached_weapons = {}
                cached_chars = {}
                _char_joints_cache = {}
                has_scanned_this_cutscene = false
            end
        end
    end
    layer_cg_was_true = layer_cg_now

    if not in_cutscene then return end

    if now - cutscene_start_time < ACTIVATION_DELAY then return end

    local current_ft = nil
    if scene then current_ft = sc(scene, "get_FirstTransform") end

    if not has_scanned_this_cutscene then
        -- 初次进入 CG（或者上一次过渡结束），直接扫
        log.info("[WeaponSnap] Triggering Full Scan (First entry or stable after transition)")
        force_full_scan()
        has_scanned_this_cutscene = true
        
        last_first_transform = current_ft
        transform_stable_frames = 0
        in_transition = false
    else
        -- CG 进行中，监控 FirstTransform 抖动
        if current_ft ~= last_first_transform then
            transform_stable_frames = 0
            if not in_transition then
                log.info("[WeaponSnap] CG Transition detected (FirstTransform changed)")
                in_transition = true
            end
        else
            if in_transition then
                transform_stable_frames = transform_stable_frames + 1
                if transform_stable_frames >= STABILITY_THRESHOLD then
                    in_transition = false
                    
                    local should_rescan = false
                    if #cached_chars == 0 then
                        should_rescan = true
                    else
                        for _, char in ipairs(cached_chars) do
                            -- 只有当物体彻底销毁/失效时，ds 才会是 nil
                            local ds = sc(char.go, "get_Valid")
                            if ds == nil then
                                should_rescan = true
                                break
                            end
                        end
                    end
                    
                    if should_rescan then
                        log.info("[WeaponSnap] CG Transition stabilized! Stale chars detected. Rescanning.")
                        has_scanned_this_cutscene = false -- 触发下一帧的重扫
                    else
                        log.info("[WeaponSnap] CG Transition stabilized! Chars still valid. Skipping rescan.")
                    end
                end
            end
        end
        last_first_transform = current_ft
    end

    local occupied_hands = {}

    local wp2001 = nil
    local wp0500 = nil
    for _, w in ipairs(cached_weapons) do
        w._special_snap = nil
        if w.name:find("wp2001") then
            wp2001 = w
            w._special_snap = true
        end
        if w.name:find("wp0500") then wp0500 = w end
    end

    -- ══ 性能优化：每帧只算一次 FK，缓存到角色上 ══
    for _, char in ipairs(cached_chars) do
        char._fk_r_wep = fk_wep_world_pos(char, "R")
        char._fk_l_wep = fk_wep_world_pos(char, "L")
        -- 持久化复制（vec pool 会在帧末回收）
        if char._fk_r_wep then char._fk_r_wep = { x = char._fk_r_wep.x, y = char._fk_r_wep.y, z = char._fk_r_wep.z } end
        if char._fk_l_wep then char._fk_l_wep = { x = char._fk_l_wep.x, y = char._fk_l_wep.y, z = char._fk_l_wep.z } end
    end

    for _, wep in ipairs(cached_weapons) do
        if wep._special_snap then
            -- 跳过普通吸附
        else
            pcall(function()
                if sc(wep.go, "get_Valid") then
                    local j0 = wep.j0
                    local j1 = wep.j1
                    local p0 = j0 and sc(j0, "get_Position")
                    local p1 = j1 and sc(j1, "get_Position")

                    if not p0 and not p1 then p0 = sc(wep.transform, "get_Position") end

                    if p0 or p1 then
                        local best_dist = SNAP_THRESHOLD
                        local target_char, target_snap_joint, target_wep_joint_name = nil, nil, nil
                        wep._best_cp = nil

                        for _, char in ipairs(cached_chars) do
                            if wep.exclusive_char and wep.exclusive_char ~= char.mapped_name then goto continue_char end
                            local offsets = (char.mapped_name == "Grace") and NATIVE_OFFSETS.Grace or NATIVE_OFFSETS.Leon
                            local joints = get_char_joints(char)

                            char.calc_l_wep_pos = nil
                            char.calc_r_wep_pos = nil

                            for _, j_info in ipairs(joints) do
                                local hand_key = get_hand_key(char.name, j_info.name)
                                if not occupied_hands[hand_key] and j_info.hand_j then
                                    local pure_pos = nil
                                    local snap_pos = nil
                                    local h_pos = sc(j_info.hand_j, "get_Position")
                                    local h_rot = sc(j_info.hand_j, "get_Rotation")
                                    if h_pos and h_rot then
                                        local json_offset = get_joint_offset(char.name, j_info.name)
                                        
                                        local side = (j_info.name == "R_Wep") and "R" or "L"
                                        local fk_wep_pos = (side == "R") and char._fk_r_wep or char._fk_l_wep
                                        
                                        if fk_wep_pos then
                                            pure_pos = vec3(fk_wep_pos.x, fk_wep_pos.y, fk_wep_pos.z)
                                        end

                                        -- 实际吸附坐标 (Hand + NativeOffsets + JsonOffset)
                                        local snap_offset = vec3(
                                            j_info.base_off.x + json_offset.x,
                                            j_info.base_off.y + json_offset.y,
                                            j_info.base_off.z + json_offset.z
                                        )
                                        local world_snap = quat_mul_vec(h_rot, snap_offset)
                                        snap_pos = vec3(h_pos.x + world_snap.x, h_pos.y + world_snap.y, h_pos.z + world_snap.z)

                                        -- calc 位置需要持久到帧尾 UI 显示及后续吸附，用普通 table
                                        if j_info.name == "L_Wep" then char.calc_l_wep_pos = { x = snap_pos.x, y = snap_pos.y, z = snap_pos.z } end
                                        if j_info.name == "R_Wep" then char.calc_r_wep_pos = { x = snap_pos.x, y = snap_pos.y, z = snap_pos.z } end
                                    end

                                    pure_pos = pure_pos or (j_info.wep_j and sc(j_info.wep_j, "get_Position"))
                                    snap_pos = snap_pos or pure_pos

                                    if pure_pos then
                                        local best_for_char, best_j_for_char, best_cp = 99999, nil, nil

                                        if wep.j0_to_j1 and wep.j0_to_muzzle then
                                            local p_j0 = sc(wep.j0, "get_Position")
                                            local r_j0 = sc(wep.j0, "get_Rotation")
                                            if p_j0 and r_j0 then
                                                local v1  = quat_mul_vec(r_j0, wep.j0_to_j1)
                                                local vmz = quat_mul_vec(r_j0, wep.j0_to_muzzle)
                                                local seg_a = vec3(p_j0.x+v1.x,  p_j0.y+v1.y,  p_j0.z+v1.z)
                                                local seg_b = vec3(p_j0.x+vmz.x, p_j0.y+vmz.y, p_j0.z+vmz.z)
                                                local _, dist = closest_point_on_segment(pure_pos, seg_a, seg_b)
                                                local cp, _ = closest_point_on_segment(snap_pos, seg_a, seg_b)

                                                local effective_dist = dist
                                                if j_info.name == "R_Wep" then
                                                    effective_dist = effective_dist - RIGHT_HAND_BIAS
                                                end

                                                best_for_char = effective_dist
                                                best_j_for_char = wep.j0
                                                best_cp = cp
                                            end
                                        else
                                            local d0 = p0 and math.sqrt((p0.x-pure_pos.x)^2+(p0.y-pure_pos.y)^2+(p0.z-pure_pos.z)^2) or 99999
                                            local d1 = p1 and math.sqrt((p1.x-pure_pos.x)^2+(p1.y-pure_pos.y)^2+(p1.z-pure_pos.z)^2) or 99999
                                            
                                            if wep.is_extra then
                                                -- 列表物体的逻辑：只检测 Root 和 指定骨骼 (j_extra)
                                                local best_d, best_j = d0, j0
                                                if wep.j_extra then
                                                    local pf = sc(wep.j_extra, "get_Position")
                                                    if pf then
                                                        local df = math.sqrt((pf.x-pure_pos.x)^2+(pf.y-pure_pos.y)^2+(pf.z-pure_pos.z)^2)
                                                        if df < best_d then
                                                            best_d, best_j = df, wep.j_extra
                                                        end
                                                    end
                                                end
                                                best_for_char, best_j_for_char = best_d, best_j
                                            else
                                                -- 原有 wp 物体的逻辑：检测 d0 和 d1，维持原有优先级
                                                if d1 < SNAP_THRESHOLD then
                                                    best_for_char, best_j_for_char = d1, j1
                                                elseif d0 < SNAP_THRESHOLD then
                                                    best_for_char, best_j_for_char = d0, j0
                                                elseif d1 <= d0 then
                                                    best_for_char, best_j_for_char = d1, j1
                                                else
                                                    best_for_char, best_j_for_char = d0, j0
                                                end
                                            end
                                        end

                                        if best_for_char < best_dist then
                                            best_dist = best_for_char
                                            target_char = char
                                            target_snap_joint = j_info.wep_j
                                            target_wep_joint_name = j_info.name
                                            wep.active_joint = best_j_for_char
                                            -- best_cp 来自 vec pool，需要持久化
                                            if best_cp then
                                                wep._best_cp = { x = best_cp.x, y = best_cp.y, z = best_cp.z }
                                            else
                                                wep._best_cp = nil
                                            end
                                        end
                                    end
                                end
                            end
                            ::continue_char::
                        end

                        wep.dist_to_hand = best_dist
                        if target_char then
                            local hand_key = get_hand_key(target_char.name, target_wep_joint_name)
                            occupied_hands[hand_key] = true

                            local is_right = (target_wep_joint_name == "R_Wep")
                            local hand_joint = is_right and target_char.r_hand_joint or target_char.l_hand_joint

                            if hand_joint then
                                local p_hand = hand_joint:call("get_Position")
                                local r_hand = hand_joint:call("get_Rotation")

                                if p_hand and r_hand then
                                    local calc_pos = is_right and target_char.calc_r_wep_pos or target_char.calc_l_wep_pos
                                    local target_pos = nil
                                    if calc_pos then
                                        target_pos = Vector3f.new(calc_pos.x, calc_pos.y, calc_pos.z)
                                    else
                                        target_pos = p_hand
                                    end

                                    local active_joint = wep.active_joint
                                    if not active_joint then
                                        pcall(function()
                                            local joints = wep.transform:call("get_Joints")
                                            if joints then active_joint = joints[0] end
                                        end)
                                    end

                                    if active_joint then
                                        pcall(function()
                                            local parent_j = active_joint:call("get_Parent")
                                            local p_world = parent_j and parent_j:call("get_Position") or wep.transform:call("get_Position")
                                            local p_rot = parent_j and parent_j:call("get_Rotation") or wep.transform:call("get_Rotation")
                                            local p_active = active_joint:call("get_Position")

                                            if p_world and p_rot then
                                                local cp = wep._best_cp
                                                if cp and p_active then
                                                    -- 线段模式：偏移根骨骼使最近点对齐 target_pos
                                                    local snap_target = Vector3f.new(
                                                        p_active.x + (target_pos.x - cp.x),
                                                        p_active.y + (target_pos.y - cp.y),
                                                        p_active.z + (target_pos.z - cp.z)
                                                    )
                                                    local inv_rot = vec4(-p_rot.x, -p_rot.y, -p_rot.z, p_rot.w)
                                                    local world_delta = vec3(snap_target.x - p_world.x, snap_target.y - p_world.y, snap_target.z - p_world.z)
                                                    local new_local = quat_mul_vec(inv_rot, world_delta)
                                                    active_joint:call("set_LocalPosition", Vector3f.new(new_local.x, new_local.y, new_local.z))
                                                    if p_active then
                                                        wep.applied_delta = {
                                                            x = snap_target.x - p_active.x,
                                                            y = snap_target.y - p_active.y,
                                                            z = snap_target.z - p_active.z
                                                        }
                                                    else
                                                        wep.applied_delta = {x=0, y=0, z=0}
                                                    end
                                                else
                                                    -- 普通模式：直接用世界坐标 set_Position，避免父骨骼叠加偏移
                                                    local curr_pos = wep.transform:call("get_Position")
                                                    wep.transform:call("set_Position", target_pos)
                                                    wep.applied_delta = {
                                                        x = target_pos.x - curr_pos.x,
                                                        y = target_pos.y - curr_pos.y,
                                                        z = target_pos.z - curr_pos.z
                                                    }
                                                end
                                                local j_name = active_joint:call("get_Name") or "Unknown"
                                                wep.snapped_to = target_char.name .. " (" .. target_wep_joint_name .. " via " .. j_name .. ")"
                                            end
                                        end)
                                    else
                                        pcall(function()
                                            local curr_pos = wep.transform:call("get_Position")
                                            local true_world_delta = { x = target_pos.x - curr_pos.x, y = target_pos.y - curr_pos.y, z = target_pos.z - curr_pos.z }
                                            wep.transform:call("set_Position", target_pos)
                                            wep.applied_delta = true_world_delta
                                        end)
                                        wep.snapped_to = target_char.name .. " (" .. target_wep_joint_name .. " via Transform)"
                                    end
                                end
                            end
                        else
                            wep.snapped_to = nil
                            wep.applied_delta = {x=0, y=0, z=0}
                            wep.seg_cumulative_delta = {x=0, y=0, z=0}
                        end
                    end
                end
            end)
        end
    end

    -- 之后再处理 wp2001 到 wp0500 的特殊吸附，这样可以带上 wp0500 的 applied_delta
    if wp2001 and wp0500 then
        pcall(function()
            local j_src = sc(wp2001.transform, "getJointByName", "Scope_Pos_00")
            local j_dst = sc(wp0500.transform, "getJointByName", "Scope_Pos_00")
            if j_src and j_dst then
                local p_dst = sc(j_dst, "get_Position")
                local p_src = sc(j_src, "get_Position")
                local p_trans = sc(wp2001.transform, "get_Position")

                if p_dst and p_src and p_trans then
                    local target_trans_x = p_dst.x - (p_src.x - p_trans.x)
                    local target_trans_y = p_dst.y - (p_src.y - p_trans.y)
                    local target_trans_z = p_dst.z - (p_src.z - p_trans.z)

                    wp2001.transform:call("set_Position", Vector3f.new(target_trans_x, target_trans_y, target_trans_z))
                    wp2001.snapped_to = "wp0500 (Scope_Pos_00 via Transform)"
                end
            end
        end)
    end
end)

re.on_draw_ui(function()
    if imgui.tree_node("CG Weapon Snap Fix") then
        local changed, new_val = imgui.checkbox("Enabled", ENABLED)
        if changed then ENABLED = new_val end
        changed, new_val = imgui.slider_float("Snap Distance Threshold", SNAP_THRESHOLD, 0.0, 10.0, "%.3f")
        if changed then SNAP_THRESHOLD = new_val end
        changed, new_val = imgui.slider_float("Right Hand Bias (Segment)", RIGHT_HAND_BIAS, 0.0, 0.5, "%.3f")
        if changed then RIGHT_HAND_BIAS = new_val end

        local status = not in_cutscene and "Idle (not in cutscene)" or
                       (#cached_weapons == 0 or #cached_chars == 0) and "Scanning..." or "Running"
        imgui.text("Status: " .. status)
        imgui.text(string.format("Chars: %d  Weapons: %d", #cached_chars, #cached_weapons))

        if in_cutscene and #cached_chars > 0 then
            imgui.text("--- Active Target Characters ---")
            for _, char in ipairs(cached_chars) do
                local ds = sc(char.go, "get_Valid")
                local status_text = (ds == true) and "[Active]" or (ds == false) and "[Hidden]" or "[Stale/Nil]"
                
                local l_pos, r_pos = "nil", "nil"
                if char.calc_l_wep_pos then
                    l_pos = string.format("(%.1f,%.1f,%.1f)", char.calc_l_wep_pos.x, char.calc_l_wep_pos.y, char.calc_l_wep_pos.z)
                end
                if char.calc_r_wep_pos then
                    r_pos = string.format("(%.1f,%.1f,%.1f)", char.calc_r_wep_pos.x, char.calc_r_wep_pos.y, char.calc_r_wep_pos.z)
                end
                imgui.text(string.format("%s [L:%s R:%s]", char.name, l_pos, r_pos))
            end
            imgui.text("--------------------------------")

            if #cached_weapons > 0 then
                for _, wep in ipairs(cached_weapons) do
                    local w_pos = "nil"
                    local p = nil
                    if wep.j0 then p = sc(wep.j0, "get_Position") end
                    p = p or sc(wep.transform, "get_Position")
                    if p then w_pos = string.format("(%.2f, %.2f, %.2f)", p.x, p.y, p.z) end

                    local visible = sc(wep.go, "get_DrawSelf")
                    local status_text = visible and "[Active]" or "[Hidden]"
                    imgui.text(string.format("%s %s %s -> %s (D:%.3f)", status_text, wep.name, w_pos, wep.snapped_to or "Waiting", wep.dist_to_hand))
                end
            end
        end

        imgui.text("--------------------------------")
        imgui.text("CG Transition Monitor:")
        imgui.text("In Transition: " .. tostring(in_transition))
        imgui.text("Stable Frames: " .. tostring(transform_stable_frames) .. " / " .. tostring(STABILITY_THRESHOLD))
        imgui.text("--------------------------------")

        if imgui.button("Force Full Scan (Manual)") then force_full_scan() end
        imgui.same_line()
        if imgui.button("Dump State to JSON") then
            local dump = {
                in_cutscene = in_cutscene,
                cached_chars = {},
                cached_weapons = {},
                player_chars_eval = {},
                json_leon = cached_json["Leon"] and cached_json["Leon"].joints or "NOT LOADED",
                json_grace = cached_json["Grace"] and cached_json["Grace"].joints or "NOT LOADED"
            }
            
            -- 额外记录 player_chars 的检测状态
            local sm = sdk.get_native_singleton("via.SceneManager")
            local scene = sm and sdk.call_native_func(sm, type_SceneManager, "get_CurrentScene") or nil
            if scene then
                for _, pname in ipairs(PLAYER_CHARS) do
                    local go = get_player_go(scene, pname, os.clock())
                    if go then
                        local p_data = { name = pname }
                        pcall(function()
                            p_data.valid = go:call("get_Valid")
                            p_data.draw_self = go:call("get_DrawSelf")
                            local motion = go:call("getComponent(System.Type)", typeof_Motion)
                            if motion then
                                local layer0 = motion:call("getLayer", 0)
                                if layer0 then
                                    p_data.layer0_bank = layer0:call("get_MotionBankID")
                                    p_data.layer0_mot = layer0:call("get_MotionID")
                                end
                            end
                        end)
                        table.insert(dump.player_chars_eval, p_data)
                    end
                end
            end

            for _, c in ipairs(cached_chars) do
                local c_data = { name = c.name }
                
                pcall(function()
                    c_data.valid = c.go:call("get_Valid")
                    c_data.draw_self = c.go:call("get_DrawSelf")
                    
                    local motion = c.go:call("getComponent(System.Type)", typeof_Motion)
                    if motion then
                        local layer0 = motion:call("getLayer", 0)
                        if layer0 then
                            c_data.layer0_bank = layer0:call("get_MotionBankID")
                            c_data.layer0_mot = layer0:call("get_MotionID")
                        end
                        local layer3 = motion:call("getLayer", 3)
                        if layer3 then
                            c_data.layer3_bank = layer3:call("get_MotionBankID")
                            c_data.layer3_mot = layer3:call("get_MotionID")
                        end
                    end
                end)

                if c.l_hand_joint then
                    local p = sc(c.l_hand_joint, "get_Position")
                    if p then c_data.l_hand = {x=p.x, y=p.y, z=p.z} end
                end
                if c.r_hand_joint then
                    local p = sc(c.r_hand_joint, "get_Position")
                    if p then c_data.r_hand = {x=p.x, y=p.y, z=p.z} end
                end
                table.insert(dump.cached_chars, c_data)
            end
            for _, w in ipairs(cached_weapons) do
                local w_data = {
                    name = w.name,
                    snapped_to = w.snapped_to,
                    dist = w.dist_to_hand
                }
                local p = sc(w.transform, "get_Position")
                if p then w_data.pos = {x=p.x, y=p.y, z=p.z} end
                table.insert(dump.cached_weapons, w_data)
            end
            json.dump_file("cg_snap_debug.json", dump)
            log.info("Dumped state to cg_snap_debug.json")
        end
        imgui.tree_pop()
    end
end)
