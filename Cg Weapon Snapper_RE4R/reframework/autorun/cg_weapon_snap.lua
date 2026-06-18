-- cg_weapon_snap.lua
-- CG武器吸附右手脚本
-- 策略：钩子负责标记过场状态，轮询负责扫描场景，完全解耦

local TARGET_CHARS = {"ch0a0z0", "ch2a1z0", "ch2a200", "ch2a3z0", "ch3a8z0", "ch1b7z0"}
local SNAP_THRESHOLD = 0.1
local RIGHT_HAND_BIAS = 0.073
local ENABLED = true
local EXTRA_ITEMS = {
    -- 格式：{ "物品名", "骨骼名", "目标角色", {骨骼局部偏移 x,y,z} }
    -- 第3项（目标角色）可省略或填 nil，表示不限定角色
    -- 第4项（骨骼局部偏移）可省略，表示直接用骨骼原点判断距离
    --   偏移在该骨骼的局部坐标系下定义，会随物体旋转自动转换为世界坐标
    -- { "物品名", "骨骼名", "目标角色", {ox, oy, oz} },
    -- { "物品名", "骨骼名" },
    -- { "物品名" },

    { "ac0000_00_00", "_00" },
    { "sm78_702_00", "_00" },
    { "sm61_587_00", "_00" },
    { "sm61_649_00", "_00" },
    { "sm61_579_00", "_00", nil, {0.02, 0.0, 0.0} },
    { "sm61_547_00", "_00", nil, {-0.000068, 0.000493, -0.042006} },
    { "sm61_547_01", "_00", nil, {-0.000068, 0.000493, -0.042006} }, 
    { "sm61_591_00", "_00" },
    { "sm61_347_00", "_00", nil, {0.1, -0.01, 0.0} },
    { "sm61_630_00", "_00", nil, {-0.03, 0.0, 0.0}},
    { "sm61_630_01", "_00", nil, {0.04, 0.0, 0.0}},
    { "sm74_524_00", "_00", nil, {0.0, 0.05, 0.0}},
    { "sm61_549_00", "_00" },
    { "sm61_541_00", "_00", nil, {0.1, -0.01, 0.0} },  -- 钩锁枪：填写握把处相对 _00 的局部偏移
    { "sm61_576_00", "_00" },
    { "sm61_309_00", "_00", nil, {-0.015, -0.005, 0.0} },
    
}

local ACCESSORY_RULES = {
    -- 你可以在这里添加更多，格式：{ wep = "武器名", acc = "配件名", joints = {"首选骨骼", "备选骨骼".."} }
    { wep = "wp4000", acc = "wp4090", joints = {"_00"} },

}

local cached_weapons = {}
local cached_chars = {}
local in_cutscene = false
local last_scan_time = 0
local has_scanned_this_cutscene = false
local cutscene_start_time = 0      -- in_cutscene 第一次变 true 的时间
local _need_char_rescan = false     -- 角色骨骼失效时触发重扫（不清水武器缓存）

local ACTIVATION_DELAY = 0.0       -- 进入 CG 后等待 N 秒再开始操作
local DEACTIVATION_DELAY = 0.0     -- CG 结束后持续吸附 N 秒
local LAYER_CG_PERSIST = 0.0       -- LayerCG 持续超过此帧数才认定为 CG

local layer_cg_true_since = 0      -- LayerCG 开始为 true 的时间
local layer_cg_was_true = false    -- 上一帧 LayerCG 是否为 true
local cutscene_end_time = 0        -- CG 真正结束的时间

local cached_json = {}
local last_json_read_time = 0

local SKEL_REST = {
    Leon = {
        R_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","R_Shoulder","R_UpperArm","R_Forearm","R_Hand","R_Wep"},
        L_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","L_Shoulder","L_UpperArm","L_Forearm","L_Hand","L_Wep"},
        bones = {
            root           = { local_offset = {-0.0, 0.0, 0.0}, local_rest_rot = {0.707107, 0.0, 0.0, 0.707107} },
            Hip            = { local_offset = {0.0, 0.99882, -0.0}, local_rest_rot = {0.0, 0.0, 0.0, 1.0} },
            Spine_0        = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {-0.000444, 0.0, 0.0, 1.0} },
            Spine_1        = { local_offset = {-0.0, 0.161447, 0.0}, local_rest_rot = {-0.059427, 0.0, 0.0, 0.998233} },
            Spine_2        = { local_offset = {-0.0, 0.161341, 0.0}, local_rest_rot = {0.002506, 0.0, 0.0, 0.999997} },
            R_Shoulder     = { local_offset = {-0.036476, 0.138379, 0.054999}, local_rest_rot = {-0.011376, 0.08641, 0.13003, 0.987672} },
            R_UpperArm     = { local_offset = {-0.141675, 0.005581, -0.049021}, local_rest_rot = {0.21479, 0.104869, 0.162034, 0.957399} },
            R_Forearm      = { local_offset = {-0.277009, 0.0, 0.0}, local_rest_rot = {0.0, 0.407672, -0.0, 0.913128} },
            R_Hand         = { local_offset = {-0.263651, -0.0, -0.0}, local_rest_rot = {0.110658, -0.010367, -0.05946, 0.992024} },
            R_Wep          = { local_offset = {-0.076475, -0.02557, 0.008051}, local_rest_rot = {-0.0, 0.0, -0.0, 1.0} },
            L_Shoulder     = { local_offset = {0.036476, 0.138379, 0.054999}, local_rest_rot = {-0.011376, -0.08641, -0.130029, 0.987672} },
            L_UpperArm     = { local_offset = {0.141675, 0.005581, -0.049021}, local_rest_rot = {0.21479, -0.104869, -0.162034, 0.957399} },
            L_Forearm      = { local_offset = {0.277009, 0.0, 0.0}, local_rest_rot = {0.0, -0.407673, -0.0, 0.913128} },
            L_Hand         = { local_offset = {0.263651, 0.0, -0.0}, local_rest_rot = {0.110658, 0.010367, 0.05946, 0.992024} },
            L_Wep          = { local_offset = {0.076475, -0.02557, 0.008051}, local_rest_rot = {-0.0, -0.0, 0.0, 1.0} }
        }
    },

    Luis = {
        R_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","R_Shoulder","R_UpperArm","R_Forearm","R_Hand","R_Wep"},
        L_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","L_Shoulder","L_UpperArm","L_Forearm","L_Hand","L_Wep"},
        bones = {
            root           = { local_offset = {-0.0, 0.0, 0.0}, local_rest_rot = {0.707107, 0.0, 0.0, 0.707107} },
            Hip            = { local_offset = {0.0, 0.99882, -0.0}, local_rest_rot = {0.0, 0.0, 0.0, 1.0} },
            Spine_0        = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {-0.000444, 0.0, 0.0, 1.0} },
            Spine_1        = { local_offset = {-0.0, 0.161447, 0.0}, local_rest_rot = {-0.059427, 0.0, 0.0, 0.998233} },
            Spine_2        = { local_offset = {-0.0, 0.161341, 0.0}, local_rest_rot = {0.002506, 0.0, 0.0, 0.999997} },
            R_Shoulder     = { local_offset = {-0.036476, 0.138379, 0.054999}, local_rest_rot = {-0.011376, 0.08641, 0.13003, 0.987672} },
            R_UpperArm     = { local_offset = {-0.141675, 0.005581, -0.049021}, local_rest_rot = {0.21479, 0.104869, 0.162034, 0.957399} },
            R_Forearm      = { local_offset = {-0.277009, 0.0, 0.0}, local_rest_rot = {0.0, 0.407672, -0.0, 0.913128} },
            R_Hand         = { local_offset = {-0.263651, -0.0, -0.0}, local_rest_rot = {0.110658, -0.010367, -0.05946, 0.992024} },
            R_Wep          = { local_offset = {-0.076475, -0.02557, 0.008051}, local_rest_rot = {-0.0, 0.0, -0.0, 1.0} },
            L_Shoulder     = { local_offset = {0.036476, 0.138379, 0.054999}, local_rest_rot = {-0.011376, -0.08641, -0.130029, 0.987672} },
            L_UpperArm     = { local_offset = {0.141675, 0.005581, -0.049021}, local_rest_rot = {0.21479, -0.104869, -0.162034, 0.957399} },
            L_Forearm      = { local_offset = {0.277009, 0.0, 0.0}, local_rest_rot = {0.0, -0.407673, -0.0, 0.913128} },
            L_Hand         = { local_offset = {0.263651, 0.0, -0.0}, local_rest_rot = {0.110658, 0.010367, 0.05946, 0.992024} },
            L_Wep          = { local_offset = {0.076475, -0.02557, 0.008051}, local_rest_rot = {-0.0, -0.0, 0.0, 1.0} }
        }
    },

    Ashley = {
        R_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","R_Shoulder","R_UpperArm","R_Forearm","R_Hand","R_Wep"},
        L_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","L_Shoulder","L_UpperArm","L_Forearm","L_Hand","L_Wep"},
        bones = {
            root           = { local_offset = {0.0, 0.0191, -0.0}, local_rest_rot = {0.707107, 0.0, 0.0, 0.707107} },
            Hip            = { local_offset = {0.0, 1.007, -0.0}, local_rest_rot = {0.0, 0.0, 0.0, 1.0} },
            Spine_0        = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {0.042049, 0.0, 0.0, 0.999116} },
            Spine_1        = { local_offset = {0.0, 0.1373, 0.007}, local_rest_rot = {-0.072344, 0.0, 0.0, 0.99738} },
            Spine_2        = { local_offset = {0.0, 0.1048, -0.0225}, local_rest_rot = {-0.02705, 0.0, 0.0, 0.999634} },
            R_Shoulder     = { local_offset = {-0.0365, 0.1384, 0.055}, local_rest_rot = {-0.011376, 0.08641, 0.130029, 0.987672} },
            R_UpperArm     = { local_offset = {-0.0938, 0.02, -0.0455}, local_rest_rot = {0.143845, 0.045343, 0.228107, 0.961883} },
            R_Forearm      = { local_offset = {-0.2786, 0.0, 0.0}, local_rest_rot = {0.0, 0.470498, -0.0, 0.882401} },
            R_Hand         = { local_offset = {-0.2213, -0.0, -0.0}, local_rest_rot = {0.312546, 0.006661, 0.06001, 0.947982} },
            R_Wep          = { local_offset = {-0.071431, -0.027039, 0.001306}, local_rest_rot = {-0.0, 0.0, 0.0, 1.0} },
            L_Shoulder     = { local_offset = {0.0365, 0.1384, 0.055}, local_rest_rot = {-0.011376, -0.08641, -0.130029, 0.987672} },
            L_UpperArm     = { local_offset = {0.0938, 0.02, -0.0455}, local_rest_rot = {0.143845, -0.045343, -0.228107, 0.961884} },
            L_Forearm      = { local_offset = {0.2786, 0.0, 0.0}, local_rest_rot = {0.0, -0.470498, 1e-06, 0.882401} },
            L_Hand         = { local_offset = {0.2213, -0.0, 0.0}, local_rest_rot = {0.312545, -0.006662, -0.06001, 0.947982} },
            L_Wep          = { local_offset = {0.071431, -0.027039, 0.001306}, local_rest_rot = {-0.0, -0.0, -0.0, 1.0} }
        }
    },

    Ada = {
        R_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","R_Shoulder","R_UpperArm","R_Forearm","R_Hand","R_Wep"},
        L_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","L_Shoulder","L_UpperArm","L_Forearm","L_Hand","L_Wep"},
        bones = {
            root           = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {0.707107, 0.0, 0.0, 0.707107} },
            Hip            = { local_offset = {0.0, 1.015, 0.017}, local_rest_rot = {0.0, 0.0, 0.0, 1.0} },
            Spine_0        = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {0.043619, 0.0, 0.0, 0.999048} },
            Spine_1        = { local_offset = {0.0, 0.13703, 0.0}, local_rest_rot = {-0.087156, 0.0, 0.0, 0.996195} },
            Spine_2        = { local_offset = {0.0, 0.115, 0.0}, local_rest_rot = {0.043619, 0.0, 0.0, 0.999048} },
            R_Shoulder     = { local_offset = {-0.036476, 0.133308, 0.0184}, local_rest_rot = {-0.041785, 0.081187, 0.088306, 0.9919} },
            R_UpperArm     = { local_offset = {-0.090573, 0.002227, -0.059805}, local_rest_rot = {0.145144, 0.030392, 0.282606, 0.947704} },
            R_Forearm      = { local_offset = {-0.2786, 0.0, -0.0}, local_rest_rot = {-0.0, 0.438371, 0.0, 0.898794} },
            R_Hand         = { local_offset = {-0.2213, 0.0, -0.0}, local_rest_rot = {0.325611, 0.061699, -0.035055, 0.942837} },
            R_Wep          = { local_offset = {-0.06219, -0.020736, 0.002}, local_rest_rot = {0.0, -0.0, 0.0, 1.0} },
            L_Shoulder     = { local_offset = {0.036476, 0.133308, 0.0184}, local_rest_rot = {-0.041785, -0.081187, -0.088306, 0.9919} },
            L_UpperArm     = { local_offset = {0.090573, 0.002226, -0.059805}, local_rest_rot = {0.145144, -0.030392, -0.282606, 0.947704} },
            L_Forearm      = { local_offset = {0.2786, 0.0, 0.0}, local_rest_rot = {0.0, -0.438371, 0.0, 0.898794} },
            L_Hand         = { local_offset = {0.2213, 0.0, -0.0}, local_rest_rot = {0.325611, -0.061699, 0.035055, 0.942837} },
            L_Wep          = { local_offset = {0.06219, -0.020736, 0.002}, local_rest_rot = {0.0, -0.0, -0.0, 1.0} }
        }
    },

    Krauser = {
        R_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","R_Shoulder","R_UpperArm","R_Forearm","R_Hand","R_Wep"},
        L_chain = {"root","Hip","Spine_0","Spine_1","Spine_2","L_Shoulder","L_UpperArm","L_Forearm","L_Hand","L_Wep"},
        bones = {
            root           = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {0.707107, 0.0, 0.0, 0.707107} },
            Hip            = { local_offset = {0.0, 1.048761, 0.0}, local_rest_rot = {0.0, 0.0, 0.0, 1.0} },
            Spine_0        = { local_offset = {0.0, 0.0, 0.0}, local_rest_rot = {-0.000444, 0.0, 0.0, 1.0} },
            Spine_1        = { local_offset = {-0.0, 0.16952, 0.0}, local_rest_rot = {-0.059427, 0.0, 0.0, 0.998233} },
            Spine_2        = { local_offset = {0.0, 0.177213, 0.001918}, local_rest_rot = {0.002507, 0.0, 0.0, 0.999997} },
            R_Shoulder     = { local_offset = {-0.036476, 0.138379, 0.054999}, local_rest_rot = {0.041159, 0.029853, 0.085905, 0.995005} },
            R_UpperArm     = { local_offset = {-0.156, 0.0, -0.065}, local_rest_rot = {0.061261, 0.060049, 0.34635, 0.934175} },
            R_Forearm      = { local_offset = {-0.315, -0.0, -0.0}, local_rest_rot = {-0.0, 0.370557, 0.0, 0.92881} },
            R_Hand         = { local_offset = {-0.265, 0.0, 0.0}, local_rest_rot = {0.131832, 0.038669, -0.040258, 0.989699} },
            R_Wep          = { local_offset = {-0.080988, -0.032179, 0.014334}, local_rest_rot = {0.0, 0.0, -0.0, 1.0} },
            L_Shoulder     = { local_offset = {0.036476, 0.138379, 0.054999}, local_rest_rot = {0.041159, -0.029853, -0.085905, 0.995005} },
            L_UpperArm     = { local_offset = {0.156, -0.0, -0.065}, local_rest_rot = {0.061261, -0.060049, -0.34635, 0.934175} },
            L_Forearm      = { local_offset = {0.315, -0.0, 0.0}, local_rest_rot = {-0.0, -0.370557, -0.0, 0.92881} },
            L_Hand         = { local_offset = {0.265, 0.0, 0.0}, local_rest_rot = {0.131832, -0.038669, 0.040258, 0.989699} },
            L_Wep          = { local_offset = {0.080989, -0.032179, 0.014334}, local_rest_rot = {0.0, 0.0, 0.0, 1.0} }
        }
    }
}


-- ─────────────────────────────────────────────────────────────────
-- 性能优化：缓存 sdk 类型查找结果（避免每帧重复查找）
-- ─────────────────────────────────────────────────────────────────
local type_SceneManager = sdk.find_type_definition("via.SceneManager")
local typeof_Motion = sdk.typeof("via.motion.Motion")

-- ─────────────────────────────────────────────────────────────────
-- 性能优化：sc() 无限制版 -- 直接传入函数引用给 pcall
-- ─────────────────────────────────────────────────────────────────
local function sc(obj, method, ...)
    if not obj then return nil end
    local ok, r = pcall(function(...) return obj:call(method, ...) end, ...)
    return ok and r or nil
end

-- ─────────────────────────────────────────────────────────────────
-- 性能优化：可复用临时 table 池（避免热循环中大量 {x=,y=,z=} 分配）
-- ─────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────
-- 性能优化：缓存角色名 -> mapped_name 映射（避免每帧重复字符串匹配）
-- ─────────────────────────────────────────────────────────────────
local _char_mapped_name_cache = {}

local function get_mapped_name(char_name)
    local name = tostring(char_name or ""):lower()
    if name:find("ch2a1z0") or name:find("ashley") then return "Ashley" end
    if name:find("ch2a200") or name:find("ch3a8z0") or name:find("ada") then return "Ada" end
    if name:find("ch2a3z0") or name:find("luis") then return "Luis" end
    if name:find("ch1b7z0") or name:find("krauser") then return "Krauser" end
    return "Leon"
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

-- ─────────────────────────────────────────────────────────────────

local typeof_Motion = sdk.typeof("via.motion.ActorMotion")
local function check_layer_cg(go)
    if not go then return false end
    local ok, result = pcall(function()
        if go:call("get_DrawSelf") ~= true then return false end
        if go:call("get_Valid") ~= true then return false end
        local motion = go:call("getComponent(System.Type)", typeof_Motion)
        if not motion then return false end

        local layer0 = motion:call("getLayer", 0)
        if not layer0 then return false end
        local bank0 = layer0:call("get_MotionBankID")
        local mot0 = layer0:call("get_MotionID")
        
        -- 判断 Bank 0 且 MotID 大于或等于 1 旦是 100 的倍数
        if (bank0 == 0 and (mot0 ~= -1 and mot0 ~= 4294967295)) then
            return true
        end
        return false
    end)
    return ok and result == true
end
-- 极简 CG 检测逻辑：直接读取 GuiManager 的 canDemoSkip
-- ─────────────────────────────────────────────────────────────────
local gui_field_canDemoSkip = nil
local function check_if_in_cg()
    local gui_mgr = sdk.get_managed_singleton(sdk.game_namespace("GuiManager"))
    if gui_mgr then
        -- 优先检测 IsPlayingEvent（RE4 专用）
        local ok_event, is_event = pcall(function() return gui_mgr:call("get_IsPlayingEvent") end)
        if ok_event and is_event ~= nil then
            return is_event == true
        end

        if not gui_field_canDemoSkip then
            local fields = gui_mgr:get_type_definition():get_fields()
            for _, f in ipairs(fields) do
                if f:get_name():find("canDemoSkip") then
                    gui_field_canDemoSkip = f
                    break
                end
            end
        end
        if gui_field_canDemoSkip then
            return gui_field_canDemoSkip:get_data(gui_mgr) == true
        end
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────
-- 性能优化：缓存 hand_key 字符串（避免热循环中每帧字符串拼接）
-- ─────────────────────────────────────────────────────────────────
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
                if name:find(cname) then
                    is_char = true
                    -- RE4 暂时不检查主线
                    --[[
                    local p_t = sc(cur, "get_Parent")
                    if p_t then
                        local p_go = sc(p_t, "get_GameObject")
                        if p_go then
                            local pname = tostring(sc(p_go, "get_Name") or "")
                            if not pname:find("ConstraintUniversalPositionRoot") then
                                is_char = false
                            end
                        end
                    end
                    --]]
                    break
                end
            end

            if is_char then
                local found = false
                for _, c in ipairs(cached_chars) do if c.transform == cur then found = true; break end end
                if not found then
                    local j_rhand = sc(cur, "getJointByName", "R_Arm_Hand") or sc(cur, "getJointByName", "R_Hand")
                    local j_lhand = sc(cur, "getJointByName", "L_Arm_Hand") or sc(cur, "getJointByName", "L_Hand")
                    local j_rwep  = sc(cur, "getJointByName", "R_Wep")
                    local j_lwep  = sc(cur, "getJointByName", "L_Wep")
                    
                    local char_entry = {
                        name = name, go = go, transform = cur,
                        r_hand_joint = j_rhand, l_hand_joint = j_lhand,
                        r_wep_joint = j_rwep, l_wep_joint = j_lwep,
                        mapped_name = get_mapped_name(name),
                        r_fk_joints = {}, l_fk_joints = {}
                    }

                    local skel = SKEL_REST[char_entry.mapped_name]
                    if skel then
                        for _, bname in ipairs(skel.R_chain or {}) do
                            local j = sc(cur, "getJointByName", bname)
                            if not j and bname == "root" then j = cur end
                            char_entry.r_fk_joints[bname] = j
                        end
                        for _, bname in ipairs(skel.L_chain or {}) do
                            local j = sc(cur, "getJointByName", bname)
                            if not j and bname == "root" then j = cur end
                            char_entry.l_fk_joints[bname] = j
                        end

                        -- （移除了静态的 calc_add_offset 逻辑，改为每帧动态计算）
                    end

                    table.insert(cached_chars, char_entry)
                end
            end

            local is_extra = false
            local extra_joint_name = nil
            local exclusive_char = nil
            local extra_joint_offset = nil  -- 第4参数：骨骼局部坐标偏移
            for _, item in ipairs(EXTRA_ITEMS) do
                if name:find(item[1]) then
                    is_extra = true
                    extra_joint_name = item[2]
                    exclusive_char = item[3]
                    extra_joint_offset = item[4]  -- 可能为 nil
                    break
                end
            end

            local is_wep = lower_name:sub(1, 2) == "wp"
            if (is_wep or is_extra) and not is_char then
                -- 增加 Parent 限制：None 或者包含 ch0a0z0
                local p_t = sc(cur, "get_Parent")
                local p_name = "None"
                if p_t then
                    local p_go = sc(p_t, "get_GameObject")
                    if p_go then p_name = tostring(sc(p_go, "get_Name") or "") end
                end

                if p_name == "None" or p_name:find("ch0a0z0") then
                    local found = false
                    for _, w in ipairs(cached_weapons) do if w.transform == cur then found = true; break end end
                    if not found then
                    local w_joints = sc(cur, "get_Joints")
                    local j0 = w_joints and w_joints[0]
                    local j1 = w_joints and w_joints[1]
                    local j_muzzle = sc(cur, "getJointByName", "vfx_muzzle1")
                    local j_extra = extra_joint_name and sc(cur, "getJointByName", extra_joint_name) or nil
                    local j_base = j1 or j0
                    local base_to_muzzle = nil
                    if j_base and j_muzzle then
                        local p_base = sc(j_base, "get_Position")
                        local r_base = sc(j_base, "get_Rotation")
                        local p_muz = sc(j_muzzle, "get_Position")
                        if p_base and r_base and p_muz then
                            local inv_r = {x=-r_base.x, y=-r_base.y, z=-r_base.z, w=r_base.w}
                            local offset = quat_mul_vec(inv_r, vec3(p_muz.x-p_base.x, p_muz.y-p_base.y, p_muz.z-p_base.z))
                            base_to_muzzle = { x = offset.x, y = offset.y, z = offset.z }
                        end
                    end
                    table.insert(cached_weapons, { 
                        name=name, go=go, transform=cur, 
                        j0=j0, j1=j1, j_muzzle=j_muzzle, 
                        j_extra=j_extra, 
                        j_extra_local_off = extra_joint_offset,  -- {x,y,z} 或 nil
                        has_custom_joint = (extra_joint_name ~= nil),
                        custom_joint_name = extra_joint_name,
                        is_extra=is_extra,
                        exclusive_char=exclusive_char, 
                        j_base=j_base, base_to_muzzle=base_to_muzzle, 
                        snapped_to=nil, dist_to_hand=-1 
                    })
                end
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

-- ─────────────────────────────────────────────────────────────────
-- 预构建每个角色的关节信息表（避免热循环中每帧创建 joints table）
-- ─────────────────────────────────────────────────────────────────
local _char_joints_cache = {}   -- char.transform -> { {name, wep_j, hand_j, base_off}, ... }

-- 四元数乘法：q1 * q2
local function quat_mul(q1, q2)
    return vec4(
        q1.w*q2.x + q1.x*q2.w + q1.y*q2.z - q1.z*q2.y,
        q1.w*q2.y - q1.x*q2.z + q1.y*q2.w + q1.z*q2.x,
        q1.w*q2.z + q1.x*q2.y - q1.y*q2.x + q1.z*q2.w,
        q1.w*q2.w - q1.x*q2.x - q1.y*q2.y - q1.z*q2.z
    )
end

local function fk_wep_world_pos(char, side)
    local skel = SKEL_REST[char.mapped_name]
    if not skel or not skel.bones then return nil end

    local chain  = (side == "R") and skel.R_chain or skel.L_chain
    local jcache = (side == "R") and char.r_fk_joints or char.l_fk_joints

    local prev_pos, prev_rot = nil, nil
    local hand_pos = nil

    for i, bname in ipairs(chain) do
        local j = jcache[bname]
        -- 动态重试：扫描时骨骼可能还未初始化，每帧补充获取
        if not j and bname ~= "root" then
            j = sc(char.transform, "getJointByName", bname)
            if j then jcache[bname] = j end
        end
        if not j then return nil end

        local pos, rot

        if bname == "root" then
            pos = sc(j, "get_Position")
            rot = sc(j, "get_Rotation")
            if not pos or not rot then return nil end

        elseif bname == "Hip" then
            -- Hip：使用游戏的局部坐标，以兼容 Mod 对根骨骼高度/位移的修改
            local local_pos = sc(j, "get_LocalPosition")
            local lr  = sc(j, "get_LocalRotation")
            if not local_pos or not lr or not prev_pos or not prev_rot then return nil end

            local rotated = quat_mul_vec(prev_rot, vec3(local_pos.x, local_pos.y, local_pos.z))
            pos = vec3(prev_pos.x + rotated.x, prev_pos.y + rotated.y, prev_pos.z + rotated.z)
            rot = quat_mul(prev_rot, lr)

        else
            -- 所有非 root、非 Hip 骨骼：位移用 JSON local_offset
            local bdata = skel.bones[bname]
            local off = bdata and bdata.local_offset
            local lr  = sc(j, "get_LocalRotation")
            if not off or not lr or not prev_pos or not prev_rot then return nil end

            local rotated = quat_mul_vec(prev_rot, vec3(off[1], off[2], off[3]))
            pos = vec3(prev_pos.x + rotated.x, prev_pos.y + rotated.y, prev_pos.z + rotated.z)
            rot = quat_mul(prev_rot, lr)
        end
        
        if bname == side .. "_Hand" then
            hand_pos = pos
        end

        prev_pos, prev_rot = pos, rot
    end

    -- 链的最后一个元素已经是 Wep，所以 prev_pos 就是 Wep 的坐标，不用再次叠加 Wep offset
    return prev_pos, hand_pos, prev_rot
end


-- 精确计算 wep_joint 相对 hand_joint 的局部偏移
-- 直接用世界坐标差 + 逆旋转，自动包含所有中间骨骼，精度最高
-- 每个角色独立调用，互不干扰
local function get_char_joints(char)
    local entry = _char_joints_cache[char.transform]
    if entry then return entry end

    local skel = SKEL_REST[char.mapped_name]
    
    local r_native = {0,0,0}
    if skel and skel.bones and skel.bones["R_Wep"] and skel.bones["R_Wep"].local_offset then
        local fb = skel.bones["R_Wep"].local_offset
        r_native = { x=fb[1], y=fb[2], z=fb[3] }
    end

    local l_native = {0,0,0}
    if skel and skel.bones and skel.bones["L_Wep"] and skel.bones["L_Wep"].local_offset then
        local fb = skel.bones["L_Wep"].local_offset
        l_native = { x=fb[1], y=fb[2], z=fb[3] }
    end

    entry = {
        {
            name = "R_Wep", wep_j = char.r_wep_joint, hand_j = char.r_hand_joint,
            native_off = r_native,
            add_off    = {x=0,y=0,z=0}
        },
        {
            name = "L_Wep", wep_j = char.l_wep_joint, hand_j = char.l_hand_joint,
            native_off = l_native,
            add_off    = {x=0,y=0,z=0}
        }
    }
    _char_joints_cache[char.transform] = entry
    return entry
end

-- ─────────────────────────────────────────────────────────────────
-- 逐帧全程诊断录制
-- ─────────────────────────────────────────────────────────────────
local function fmt_v(v)
    if not v then return "nil" end
    return string.format("(%.5f,%.5f,%.5f)", v.x, v.y, v.z)
end

local function fmt_q(q)
    if not q then return "nil" end
    return string.format("(%.5f,%.5f,%.5f,%.5f)", q.x, q.y, q.z, q.w)
end

local _diag_file      = nil   -- io handle
local _diag_frame     = 0     -- 当前帧编号
local _diag_recording = false -- 是否正在录制

local function diag_open()
    local path = "re4_game_diag_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
    _diag_file = io.open(path, "w")
    if _diag_file then
        _diag_frame     = 0
        _diag_recording = true
        _diag_file:write(string.format("=== RE4 Game Diag Start @ %s ===\n", os.date("%Y-%m-%d %H:%M:%S")))
        _diag_file:write("Format: FRAME | CHAR bone [Game]=pos [FK]=pos | WEP name j0=pos j1=pos\n\n")
        log.info("[WeaponSnap] RE4 Game Diag recording started: " .. path)
    end
end

local function diag_close()
    if _diag_file then
        _diag_file:write(string.format("\n=== RE4 Game Diag End  (total %d frames) ===\n", _diag_frame))
        _diag_file:close()
        _diag_file = nil
        log.info("[WeaponSnap] RE4 Game Diag recording stopped.")
    end
    _diag_recording = false
end

local function diag_write_frame()
    if not _diag_file then return end
    _diag_frame = _diag_frame + 1
    local f = _diag_file
    f:write(string.format("\n--- Frame %d ---\n", _diag_frame))

    for _, char in ipairs(cached_chars) do
        if check_layer_cg(char.go) then
            local skel = SKEL_REST[char.mapped_name]
            f:write(string.format("CHAR %s (mapped=%s)\n", char.name, tostring(char.mapped_name)))

            local function walk_chain(chain, jcache)
                local fk_prev_pos, fk_prev_rot = nil, nil
                for _, bname in ipairs(chain) do
                    local j = jcache[bname]
                    local game_pos  = j and sc(j, "get_Position") or nil
                    local game_rot  = j and sc(j, "get_Rotation") or nil
                    local local_rot = j and sc(j, "get_LocalRotation") or nil
                    local local_pos = j and sc(j, "get_LocalPosition") or nil

                    -- FK 积累（与 fk_wep_world_pos 完全一致）
                    local fk_pos, fk_rot = nil, nil
                    if bname == "root" then
                        fk_pos = game_pos
                        fk_rot = game_rot
                    elseif bname == "Hip" then
                        if local_pos and local_rot and fk_prev_pos and fk_prev_rot then
                            local rotated = quat_mul_vec(fk_prev_rot, vec3(local_pos.x, local_pos.y, local_pos.z))
                            fk_pos = { x = fk_prev_pos.x+rotated.x, y = fk_prev_pos.y+rotated.y, z = fk_prev_pos.z+rotated.z }
                            fk_rot = quat_mul(fk_prev_rot, local_rot)
                        end
                    elseif skel and skel.bones[bname] and fk_prev_pos and fk_prev_rot then
                        local bdata = skel.bones[bname]
                        local off = bdata and bdata.local_offset
                        if off then
                            local rotated = quat_mul_vec(fk_prev_rot, vec3(off[1], off[2], off[3]))
                            fk_pos = { x = fk_prev_pos.x+rotated.x, y = fk_prev_pos.y+rotated.y, z = fk_prev_pos.z+rotated.z }
                            if local_rot then
                                fk_rot = quat_mul(fk_prev_rot, local_rot)
                            end
                        end
                    end

                    f:write(string.format("  bone %-20s [Game]=%s [FK]=%s\n",
                        bname, fmt_v(game_pos), fmt_v(fk_pos)))
                    f:write(string.format("    world_rot=%s  local_rot=%s\n",
                        fmt_q(game_rot), fmt_q(local_rot)))
                    f:write(string.format("    local_pos=%s  fk_rot=%s\n", fmt_v(local_pos), fmt_q(fk_rot)))

                    if fk_pos then fk_prev_pos = fk_pos end
                    if fk_rot then fk_prev_rot = fk_rot end
                end
            end

            if skel then
                f:write("  -- R_chain --\n")
                walk_chain(skel.R_chain or {}, char.r_fk_joints or {})
                f:write("  -- L_chain --\n")
                walk_chain(skel.L_chain or {}, char.l_fk_joints or {})
            end
        end
    end

    -- 武器
    f:write("WEAPONS\n")
    for _, wep in ipairs(cached_weapons) do
        local p0 = wep.j0 and sc(wep.j0, "get_Position")
        local p1 = wep.j1 and sc(wep.j1, "get_Position")
        f:write(string.format("  %-40s j0=%s j1=%s\n", wep.name, fmt_v(p0), fmt_v(p1)))
    end
end



re.on_pre_application_entry("LateUpdateBehavior", function()
    if not ENABLED then return end

    local now = os.clock()

    -- 每帧重置 vec pool
    vec_pool_reset()

    -- ── 基于 UI 状态检测 CG ──────────────────────────────────────────────────────────
    local layer_cg_now = check_if_in_cg()

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
            _cg_log_done = false
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
                -- CG 结束，停止录制
                if _diag_recording then diag_close() end
            end
        end
    end
    layer_cg_was_true = layer_cg_now

    if not in_cutscene then return end

    if now - cutscene_start_time < ACTIVATION_DELAY then return end

    if not has_scanned_this_cutscene then
        log.info("[WeaponSnap] Triggering Full Scan (Entered CG)")
        force_full_scan()
        has_scanned_this_cutscene = true
        -- 注意：诊断录制默认不自动开启，请在 UI 中手动开启
    end

    -- 每帧写入诊断数据
    if _diag_recording then
        diag_write_frame()
    end

    -- 角色 transform 引用失效时：只清除角色缓存重扫（武器缓存保留）
    if _need_char_rescan then
        _need_char_rescan = false
        cached_chars = {}
        _char_joints_cache = {}
        full_scene_scan()
    end

    local occupied_hands = {}

    local active_accessories = {}
    for _, w in ipairs(cached_weapons) do
        w._special_snap = nil
    end

    for _, rule in ipairs(ACCESSORY_RULES) do
        local found_wep, found_acc
        for _, w in ipairs(cached_weapons) do
            if not found_wep and w.name:find(rule.wep) then found_wep = w end
            if not found_acc and w.name:find(rule.acc) then found_acc = w end
        end
        if found_wep and found_acc then
            found_acc._special_snap = true
            table.insert(active_accessories, { wep = found_wep, acc = found_acc, rule = rule })
        end
    end

    -- ╔══ 性能优化：每帧只算一次 FK，缓存到角色 ══╗
    -- ╚══ 性能优化：每帧只算一次 FK，缓存到角色 ══╝
    for _, char in ipairs(cached_chars) do
        -- 动态过滤：只计算处于活跃 CG 状态的角色
        if check_layer_cg(char.go) then
            char._is_active_this_frame = true
            local r_wep_p, r_hand_p, r_hand_r = fk_wep_world_pos(char, "R")
            local l_wep_p, l_hand_p, l_hand_r = fk_wep_world_pos(char, "L")
            char._fk_r_wep = r_wep_p
            char._fk_l_wep = l_wep_p
            char._fk_r_hand = r_hand_p
            char._fk_l_hand = l_hand_p
            char._fk_r_hand_rot = r_hand_r
            char._fk_l_hand_rot = l_hand_r
            if char._fk_r_hand then char._fk_r_hand = { x = char._fk_r_hand.x, y = char._fk_r_hand.y, z = char._fk_r_hand.z } end
            if char._fk_l_hand then char._fk_l_hand = { x = char._fk_l_hand.x, y = char._fk_l_hand.y, z = char._fk_l_hand.z } end
            if char._fk_r_hand_rot then char._fk_r_hand_rot = { x = char._fk_r_hand_rot.x, y = char._fk_r_hand_rot.y, z = char._fk_r_hand_rot.z, w = char._fk_r_hand_rot.w } end
            if char._fk_l_hand_rot then char._fk_l_hand_rot = { x = char._fk_l_hand_rot.x, y = char._fk_l_hand_rot.y, z = char._fk_l_hand_rot.z, w = char._fk_l_hand_rot.w } end
            --  仅用于距离检测
            --
            -- 持久化拷贝（vec pool 会在帧末回收）
            if char._fk_r_wep then char._fk_r_wep = { x = char._fk_r_wep.x, y = char._fk_r_wep.y, z = char._fk_r_wep.z } end
            if char._fk_l_wep then char._fk_l_wep = { x = char._fk_l_wep.x, y = char._fk_l_wep.y, z = char._fk_l_wep.z } end
        else
            char._is_active_this_frame = false
            char._fk_r_wep = nil
            char._fk_l_wep = nil
            char.calc_l_wep_pos = nil
            char.calc_r_wep_pos = nil
        end
    end
-- ─────────────────────────────────────────────────────────────────
    for _, wep in ipairs(cached_weapons) do
        wep.dist_to_fk = -1 -- 重置
        if wep._special_snap then
            -- 跳过普通吸附
        else
            pcall(function()
                if sc(wep.go, "get_Valid") and sc(wep.go, "get_DrawSelf") == true then
                    local j0 = wep.j0
                    local j1 = wep.j1
                    local p0 = j0 and sc(j0, "get_Position")
                    local p1 = j1 and sc(j1, "get_Position")

                    if not p0 and not p1 then p0 = sc(wep.transform, "get_Position") end

                    if p0 or p1 then
                        -- 默认距离阈值
                        local best_dist = SNAP_THRESHOLD
                        local target_char, target_snap_joint, target_wep_joint_name = nil, nil, nil
                        local best_pure_pos = nil   -- FK 预测武器位置，用于 is_extra 无骨骼时备用吸附
                        wep._best_cp = nil

                        for _, char in ipairs(cached_chars) do
                            if not char._is_active_this_frame then goto continue_char end
                            if wep.exclusive_char and wep.exclusive_char ~= char.mapped_name then goto continue_char end
                            local joints = get_char_joints(char)

                            char.calc_l_wep_pos = nil
                            char.calc_r_wep_pos = nil


                            for _, j_info in ipairs(joints) do
                                local hand_key = get_hand_key(char.name, j_info.name)
                                if not occupied_hands[hand_key] and j_info.hand_j then
                                    local side = (j_info.name == "R_Wep") and "R" or "L"
                                    local fk_wep_pos = (side == "R") and char._fk_r_wep or char._fk_l_wep

                                    -- FK 计算失败则跳过（绝不用游戏内错误骨骼坐标顶替）
                                    if not fk_wep_pos then goto continue_joint end

                                    local pure_pos = vec3(fk_wep_pos.x, fk_wep_pos.y, fk_wep_pos.z)
                                    
                                    -- 新增：提前计算 target_pos 以防止投影点在暂停时滑动
                                     local target_pos_vec3 = vec3(pure_pos.x, pure_pos.y, pure_pos.z)
                                    local snap_pos = sc(j_info.wep_j, "get_Position") or pure_pos

                                    if j_info.name == "L_Wep" then char.calc_l_wep_pos = { x = snap_pos.x, y = snap_pos.y, z = snap_pos.z } end
                                    if j_info.name == "R_Wep" then char.calc_r_wep_pos = { x = snap_pos.x, y = snap_pos.y, z = snap_pos.z } end

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
                                                best_for_char = effective_dist
                                                best_j_for_char = wep.j0
                                                best_cp = cp
                                            end
                                        else
                                            local d0 = p0 and math.sqrt((p0.x-pure_pos.x)^2+(p0.y-pure_pos.y)^2+(p0.z-pure_pos.z)^2) or 99999
                                            local d1 = p1 and math.sqrt((p1.x-pure_pos.x)^2+(p1.y-pure_pos.y)^2+(p1.z-pure_pos.z)^2) or 99999
                                            
                                            if wep.is_extra then
                                                -- 列表物体的逻辑
                                                if wep.has_custom_joint then
                                                    -- 动态重试（骨骼可能在初始化后刷新导致引用失效）
                                                    if wep.j_extra and not sc(wep.j_extra, "get_Position") then
                                                        wep.j_extra = nil
                                                    end
                                                    if not wep.j_extra and wep.custom_joint_name then
                                                        wep.j_extra = sc(wep.transform, "getJointByName", wep.custom_joint_name)
                                                    end
                                                    local j_check = wep.j_extra or wep.j0
                                                    local pf = j_check and sc(j_check, "get_Position") or p0
                                                    if pf then
                                                        local off = wep.j_extra_local_off
                                                        local pfx, pfy, pfz = pf.x, pf.y, pf.z
                                                        if off and (off[1] ~= 0 or off[2] ~= 0 or off[3] ~= 0) and j_check then
                                                            local rf = sc(j_check, "get_Rotation")
                                                            if rf then
                                                                local woff = quat_mul_vec(rf, vec3(off[1], off[2], off[3]))
                                                                pfx = pfx + woff.x
                                                                pfy = pfy + woff.y
                                                                pfz = pfz + woff.z
                                                            end
                                                        end
                                                        best_for_char = math.sqrt((pfx-pure_pos.x)^2+(pfy-pure_pos.y)^2+(pfz-pure_pos.z)^2)
                                                        best_j_for_char = j_check or j0
                                                    end
                                                else
                                                    -- 只有没写骨骼名时，才退而求其次吸附第一根骨骼 (j0)
                                                    best_for_char, best_j_for_char = d0, j0
                                                end
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

                                        -- 统一在这里扣除 RIGHT_HAND_BIAS，确保对所有武器（含物品/普通武器）都生效
                                        if j_info.name == "R_Wep" and best_for_char ~= 99999 then
                                            best_for_char = best_for_char - RIGHT_HAND_BIAS
                                        end

                                        -- 记录到 FK 的最小距离（用于 UI 显示，忽略阈值限制）
                                        if wep.dist_to_fk == -1 or best_for_char < wep.dist_to_fk then
                                            wep.dist_to_fk = best_for_char
                                        end

                                        if best_for_char < best_dist then
                                            best_dist = best_for_char
                                            target_char = char
                                            target_snap_joint = j_info.wep_j
                                            target_wep_joint_name = j_info.name
                                            wep.active_joint = best_j_for_char
                                            best_pure_pos = pure_pos  -- 保存 FK 预测位置（is_extra 无骨骼时用于直接吸附）
                                            -- best_cp 来自 vec pool，需要持久化
                                            if best_cp then
                                                wep._best_cp = { x = best_cp.x, y = best_cp.y, z = best_cp.z }
                                            else
                                                wep._best_cp = nil
                                            end
                                        end
                                    end
                                    ::continue_joint::
                                end
                            end
                            ::continue_char::
                        end

                        wep.dist_to_hand = best_dist
                        if target_char then
                            local hand_key = get_hand_key(target_char.name, target_wep_joint_name)
                            occupied_hands[hand_key] = true

                            local is_right = (target_wep_joint_name == "R_Wep")

                            -- 动态补充：扫描时骨骼可能未初始化，在此处重试
                            if not target_char.r_hand_joint then
                                target_char.r_hand_joint = sc(target_char.transform, "getJointByName", "R_Arm_Hand") or sc(target_char.transform, "getJointByName", "R_Hand")
                            end
                            if not target_char.l_hand_joint then
                                target_char.l_hand_joint = sc(target_char.transform, "getJointByName", "L_Arm_Hand") or sc(target_char.transform, "getJointByName", "L_Hand")
                            end
                            if not target_char.r_wep_joint then
                                target_char.r_wep_joint = sc(target_char.transform, "getJointByName", "R_Wep")
                                -- 同步更新 _char_joints_cache
                                local cj = _char_joints_cache[target_char.transform]
                                if cj then for _, ji in ipairs(cj) do if ji.name == "R_Wep" then ji.wep_j = target_char.r_wep_joint end end end
                            end
                            if not target_char.l_wep_joint then
                                target_char.l_wep_joint = sc(target_char.transform, "getJointByName", "L_Wep")
                                local cj = _char_joints_cache[target_char.transform]
                                if cj then for _, ji in ipairs(cj) do if ji.name == "L_Wep" then ji.wep_j = target_char.l_wep_joint end end end
                            end

                            local hand_joint = is_right and target_char.r_hand_joint or target_char.l_hand_joint

                            if not hand_joint and wep.is_extra and best_pure_pos then
                                -- is_extra 物品无法获取手部骨骼（子对象没有直接骨骼）
                                -- 直接将 transform 吸附到 FK 预测的武器位置
                                pcall(function()
                                    wep.transform:call("set_Position", Vector3f.new(best_pure_pos.x, best_pure_pos.y, best_pure_pos.z))
                                end)
                                wep.snapped_to = target_char.name .. " (via FK pos)"
                            end

                            if hand_joint then
                                local p_hand = hand_joint:call("get_Position")
                                local r_hand = hand_joint:call("get_Rotation")

                                if p_hand and r_hand then
                                    -- 吸附落点：游戏实际 R_Hand + rotate(R_Hand_rot, NATIVE_OFFSET + ADD_OFFSET)
                                    local j_info_snap = nil
                                    local joints_snap = get_char_joints(target_char)
                                    for _, ji in ipairs(joints_snap) do
                                        if ji.name == target_wep_joint_name then j_info_snap = ji; break end
                                    end
                                    local target_pos
                                    if j_info_snap then
                                        local n = j_info_snap.native_off
                                        local a = j_info_snap.add_off
                                        
                                        -- 【核心修复】计算 R_Wep 的父级与 R_Hand 的世界坐标偏移
                                        local dx, dy, dz = 0, 0, 0
                                        if j_info_snap.wep_j then
                                            local pcall_ok, p_j = pcall(function() return j_info_snap.wep_j:call("get_Parent") end)
                                            if pcall_ok and p_j then
                                                -- 检查父骨骼是否就是手部骨骼
                                                local is_same = false
                                                pcall(function() 
                                                    if p_j:call("get_Name") == hand_joint:call("get_Name") then is_same = true end
                                                end)
                                                
                                                if not is_same then
                                                    local ok_pp, p_parent = pcall(function() return p_j:call("get_Position") end)
                                                    if ok_pp and p_parent then
                                                        -- 计算父级骨骼与手的绝对世界偏差
                                                        dx = p_parent.x - p_hand.x
                                                        dy = p_parent.y - p_hand.y
                                                        dz = p_parent.z - p_hand.z
                                                    end
                                                end
                                            end
                                        end

                                        -- 转换手部的旋转为逆四元数
                                        local inv_r_hand = { x = -r_hand.x, y = -r_hand.y, z = -r_hand.z, w = r_hand.w }
                                        -- 将纯位移差值旋转到手的本地坐标系中，这就是“父级与手的相对偏移”
                                        local parent_off_local = quat_mul_vec(inv_r_hand, vec3(dx, dy, dz))

                                        -- 最终局部坐标 = JSON(n) + AddOffset(a) + 父级相对手的动态偏移(parent_off_local)
                                        local combined = vec3(n.x + a.x + parent_off_local.x, n.y + a.y + parent_off_local.y, n.z + a.z + parent_off_local.z)
                                        
                                        -- 重新把最终局部坐标旋转回世界坐标
                                        local r = { x = r_hand.x, y = r_hand.y, z = r_hand.z, w = r_hand.w }
                                        local rotated = quat_mul_vec(r, combined)
                                        target_pos = Vector3f.new(p_hand.x + rotated.x, p_hand.y + rotated.y, p_hand.z + rotated.z)
                                    else
                                        target_pos = p_hand
                                    end

                                    local active_joint = wep.active_joint
                                    if active_joint and not sc(active_joint, "get_Position") then
                                        active_joint = nil
                                    end
                                    if not active_joint then
                                        pcall(function()
                                            local joints = wep.transform:call("get_Joints")
                                            if joints then active_joint = joints[0] end
                                        end)
                                    end

                                    -- 【j_extra_local_off 修正】
                                    -- 如果配置了局部偏移，target_pos 是"手应该在的位置"，
                                    -- 但 active_joint（_00）需要停在 target_pos - 偏移(世界坐标)，
                                    -- 这样 _00 + 偏移 才正好落在手上。
                                    local off = wep.j_extra_local_off
                                    if off and (off[1] ~= 0 or off[2] ~= 0 or off[3] ~= 0) and active_joint then
                                        local rf = sc(active_joint, "get_Rotation")
                                        if rf then
                                            local woff = quat_mul_vec(rf, vec3(off[1], off[2], off[3]))
                                            target_pos = Vector3f.new(
                                                target_pos.x - woff.x,
                                                target_pos.y - woff.y,
                                                target_pos.z - woff.z
                                            )
                                        end
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
                                                elseif wep.is_extra and wep.has_custom_joint then
                                                    -- 自定义骨骼模式：只移动指定的骨骼，不移动根节点 transform
                                                    local snap_target = target_pos
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
                                                    -- 普通模式：通过移动 transform，使得 active_joint 对齐到 target_pos
                                                    local curr_pos = wep.transform:call("get_Position")
                                                    local a_pos = p_active or curr_pos
                                                    local new_pos = Vector3f.new(
                                                        curr_pos.x + (target_pos.x - a_pos.x),
                                                        curr_pos.y + (target_pos.y - a_pos.y),
                                                        curr_pos.z + (target_pos.z - a_pos.z)
                                                    )
                                                    wep.transform:call("set_Position", new_pos)
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

    -- 之后再处理配件到主武器的特殊吸附
    for _, pair in ipairs(active_accessories) do
        pcall(function()
            local w_wep = pair.wep
            local w_acc = pair.acc
            local j_src, j_dst, matched_jname
            
            for _, jname in ipairs(pair.rule.joints) do
                j_src = sc(w_acc.transform, "getJointByName", jname)
                j_dst = sc(w_wep.transform, "getJointByName", jname)
                if j_src and j_dst then
                    matched_jname = jname
                    break
                end
            end

            if j_src and j_dst then
                local p_dst = sc(j_dst, "get_Position")
                local p_src = sc(j_src, "get_Position")
                local p_trans = sc(w_acc.transform, "get_Position")

                if p_dst and p_src and p_trans then
                    local target_trans_x = p_dst.x - (p_src.x - p_trans.x)
                    local target_trans_y = p_dst.y - (p_src.y - p_trans.y)
                    local target_trans_z = p_dst.z - (p_src.z - p_trans.z)

                    w_acc.transform:call("set_Position", Vector3f.new(target_trans_x, target_trans_y, target_trans_z))
                    w_acc.snapped_to = w_wep.name .. " (" .. matched_jname .. " via Transform)"
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
        imgui.text("CG Flag (GuiManager): " .. tostring(check_if_in_cg()))
        imgui.text(string.format("Chars: %d  Weapons: %d", #cached_chars, #cached_weapons))

        if in_cutscene and #cached_chars > 0 then
            imgui.text("--- Active Target Characters ---")
            for _, char in ipairs(cached_chars) do
                local ds_valid = sc(char.go, "get_Valid")
                local ds_draw = sc(char.go, "get_DrawSelf")
                local status_text = string.format("[V:%s D:%s]", tostring(ds_valid), tostring(ds_draw))
                
                -- 获取动画信息
                local layer_id, bank_id, mot_id = -1, -1, -1
                local is_active_cg = false
                pcall(function()
                    local motion = char.go:call("getComponent(System.Type)", typeof_Motion)
                    if motion then
                        layer_id = 0
                        local layer0 = motion:call("getLayer", layer_id)
                        if layer0 then
                            bank_id = layer0:call("get_MotionBankID") or -1
                            mot_id = layer0:call("get_MotionID") or -1
                            is_active_cg = check_layer_cg(char.go)
                        end
                    end
                end)
                
                local cg_tag = is_active_cg and " [ACTIVE CG]" or ""
                local motion_text = string.format(" [L:%d B:%d M:%d]%s",layer_id, bank_id, mot_id, cg_tag)

                local parent_name = "None"
                local p_t = sc(char.transform, "get_Parent")
                if p_t then
                    local p_go = sc(p_t, "get_GameObject")
                    if p_go then parent_name = tostring(sc(p_go, "get_Name") or "Unknown") end
                end

                local l_pos, r_pos = "nil", "nil"
                if char.calc_l_wep_pos then
                    l_pos = string.format("(%.1f,%.1f,%.1f)", char.calc_l_wep_pos.x, char.calc_l_wep_pos.y, char.calc_l_wep_pos.z)
                end
                if char.calc_r_wep_pos then
                    r_pos = string.format("(%.1f,%.1f,%.1f)", char.calc_r_wep_pos.x, char.calc_r_wep_pos.y, char.calc_r_wep_pos.z)
                end
                
                if is_active_cg then
                    imgui.text_colored(string.format("%s %s%s (Parent: %s) [L:%s R:%s]", status_text, char.name, motion_text, parent_name, l_pos, r_pos), 0xFF00FF00)
                else
                    imgui.text(string.format("%s %s%s (Parent: %s) [L:%s R:%s]", status_text, char.name, motion_text, parent_name, l_pos, r_pos))
                end
            end
            imgui.text("--------------------------------")

            if #cached_weapons > 0 then
                for _, wep in ipairs(cached_weapons) do
                    local w_pos = "nil"
                    local p = nil
                    if wep.j0 then p = sc(wep.j0, "get_Position") end
                    p = p or sc(wep.transform, "get_Position")
                    if p then w_pos = string.format("(%.2f, %.2f, %.2f)", p.x, p.y, p.z) end

                    local valid = sc(wep.go, "get_Valid")
                    local status_text = "[V:" .. ((valid == nil) and "nil" or tostring(valid)) .. "]"

                    local parent_name = "None"
                    local p_t = sc(wep.transform, "get_Parent")
                    if p_t then
                        local p_go = sc(p_t, "get_GameObject")
                        if p_go then parent_name = tostring(sc(p_go, "get_Name") or "Unknown") end
                    end

                    imgui.text(string.format("%s %s (Parent: %s) %s -> %s (D:%.3f / FK:%.3f)", status_text, wep.name, parent_name, w_pos, wep.snapped_to or "Waiting", wep.dist_to_hand, wep.dist_to_fk or -1))
                end
            end
        end

        imgui.text("--------------------------------")
        imgui.text("CG Transition Monitor:")
        imgui.text("In Transition: " .. tostring(in_transition))
        imgui.text("Stable Frames: " .. tostring(transform_stable_frames) .. " / " .. tostring(STABILITY_THRESHOLD))
        imgui.text("--------------------------------")

        -- 诊断录制开关（默认不开启，每帧写磁盘会影响性能）
        if _diag_recording then
            if imgui.button("■ 停止诊断录制") then diag_close() end
        else
            if imgui.button("● 开始诊断录制") then diag_open() end
        end
        imgui.same_line()
        imgui.text_colored("(录制中会影响帧率)", _diag_recording and 0xFF0088FF or 0xFF888888)

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
