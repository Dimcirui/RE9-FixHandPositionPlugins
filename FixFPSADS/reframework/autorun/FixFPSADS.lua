local is_enabled = true
local auto_x = true
local auto_y = false
local auto_z = false
local target_y = -0.05
local target_z = 0.05
local smooth_speed = 10.0
local allow_third_person = false

-- Internal transition state
local cur_x, cur_y, cur_z = 0, 0, 0
local is_aiming = false

local function get_active_weapon_transform(scene, player)
    local pe = player:call("getComponent(System.Type)", sdk.typeof("app.PlayerEquipment"))
    if pe then
        local ok_eid, eid = pcall(pe.get_field, pe, "<EquipWeaponID>k__BackingField")
        if ok_eid and eid then
            local ok_s, eid_str = pcall(eid.call, eid, "ToString()")
            if not ok_s or not eid_str then
                local ok_v, val = pcall(eid.get_field, eid, "value__")
                if ok_v then eid_str = tostring(val) end
            end
            if eid_str then
                eid_str = eid_str:lower()
                local wep_go = scene:call("findGameObject(System.String)", eid_str)
                if wep_go then
                    return wep_go:call("get_Transform")
                end
            end
        end
    end
    -- Fallback: try to find common weapon names
    for _, name in ipairs({"arm0000", "arm0001", "arm0003", "arm0004", "arm0005", "arm0006", "arm0007", "arm0100", "arm0103", "arm0104", "arm0400_leon", "arm0400_grace", "arm0500", "arm0501", "arm0503", "arm0505", "arm0600", "arm0601"}) do
        local w = scene:call("findGameObject(System.String)", name)
        if w then return w:call("get_Transform") end
    end
    return nil
end

local function inverse_quat(q)
    return { w = q.w, x = -q.x, y = -q.y, z = -q.z }
end

local function quat_mul_vec3(q, v)
    local qv = { x = q.x, y = q.y, z = q.z }
    local uv = {
        x = qv.y * v.z - qv.z * v.y,
        y = qv.z * v.x - qv.x * v.z,
        z = qv.x * v.y - qv.y * v.x
    }
    local uuv = {
        x = qv.y * uv.z - qv.z * uv.y,
        y = qv.z * uv.x - qv.x * uv.z,
        z = qv.x * uv.y - qv.y * uv.x
    }
    return {
        x = v.x + ((uv.x * q.w) + uuv.x) * 2.0,
        y = v.y + ((uv.y * q.w) + uuv.y) * 2.0,
        z = v.z + ((uv.z * q.w) + uuv.z) * 2.0
    }
end

local function apply_joint_offset(transform, joint_name, world_delta)
    local joint = transform:call("getJointByName", joint_name)
    if not joint then return end
    
    local parent = joint:call("get_Parent")
    if not parent then return end
    
    local p_rot = parent:call("get_Rotation")
    if not p_rot then return end
    
    local inv_p_rot = inverse_quat(p_rot)
    local local_delta = quat_mul_vec3(inv_p_rot, world_delta)
    local cur_local = joint:call("get_LocalPosition")
    if not cur_local then return end
    
    joint:call("set_LocalPosition", Vector3f.new(
        cur_local.x + local_delta.x,
        cur_local.y + local_delta.y,
        cur_local.z + local_delta.z
    ))
end

re.on_application_entry("LateUpdateBehavior", function()
    if not is_enabled then return end

    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return end
    local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end
    local player = scene:call("findGameObject(System.String)", "cp_A000")
    if not player then return end

    local pos_setting = player:call("getComponent(System.Type)", sdk.typeof("app.PlayerCameraPositionSetting"))
    is_aiming = false
    
    local char_mgr = sdk.get_managed_singleton("app.CharacterManager")
    if char_mgr and pos_setting then
        local ok_ctx, ctx = pcall(char_mgr.call, char_mgr, "get_PlayerContextFast")
        if ok_ctx and ctx then
            local ok_vm, view_mode = pcall(ctx.get_field, ctx, "<CurrentViewMode>k__BackingField")
            local is_first_person = (ok_vm and tonumber(view_mode) == 1)
            
            if is_first_person or allow_third_person then
                local ok_h, is_hold = pcall(pos_setting.get_field, pos_setting, "_IsHold")
                if ok_h and is_hold == true then
                    is_aiming = true
                end
            end
        end
    end

    if not is_aiming then
        -- Interpolate back to 0 when not aiming
        cur_x = cur_x + (0 - cur_x) * 0.1
        cur_y = cur_y + (0 - cur_y) * 0.1
        cur_z = cur_z + (0 - cur_z) * 0.1
        return
    end

    local cam = sdk.get_primary_camera()
    if not cam then return end
    local cam_go = cam:call("get_GameObject")
    if not cam_go then return end
    local cam_xform = cam_go:call("get_Transform")
    if not cam_xform then return end

    local wep_xform = get_active_weapon_transform(scene, player)
    if not wep_xform then return end

    local c_pos = cam_xform:call("get_Position")
    local c_rot = cam_xform:call("get_Rotation")
    local w_pos = wep_xform:call("get_Position")

    if not c_pos or not c_rot or not w_pos then return end

    -- Convert weapon position to camera local space
    local w_rel = {
        x = w_pos.x - c_pos.x,
        y = w_pos.y - c_pos.y,
        z = w_pos.z - c_pos.z
    }
    local c_rot_inv = inverse_quat(c_rot)
    local w_local = quat_mul_vec3(c_rot_inv, w_rel)

    -- Calculate target offsets
    -- If auto_y/z are false, we do NOT offset the camera in Y/Z, leaving it exactly where the game wants it.
    local to_x = auto_x and w_local.x or 0.0
    local to_y = auto_y and (w_local.y - target_y) or 0.0
    local to_z = auto_z and (w_local.z - target_z) or 0.0

    -- Smooth interpolation
    cur_x = cur_x + (to_x - cur_x) * smooth_speed * 0.016
    cur_y = cur_y + (to_y - cur_y) * smooth_speed * 0.016
    cur_z = cur_z + (to_z - cur_z) * smooth_speed * 0.016

    -- The required offset to the arms is the INVERSE of the camera offset
    local world_offset = quat_mul_vec3(c_rot, {x = -cur_x, y = -cur_y, z = -cur_z})
    
    local player_xform = player:call("get_Transform")
    if player_xform then
        apply_joint_offset(player_xform, "R_Arm_Clavicle", world_offset)
        apply_joint_offset(player_xform, "L_Arm_Clavicle", world_offset)
    end
end)

re.on_draw_ui(function()
    if imgui.collapsing_header("Dynamic Auto-Centering Aim") then
        local changed, val = imgui.checkbox("Enable Dynamic Aim Fix", is_enabled)
        if changed then is_enabled = val end

        imgui.text("Status: " .. (is_aiming and "AIMING" or "IDLE"))

        imgui.separator()
        imgui.text("Settings:")
        
        local c3, v3 = imgui.checkbox("Allow in Third Person (Funny Glitch)", allow_third_person)
        if c3 then allow_third_person = v3 end

        local cx, vx = imgui.checkbox("Auto-Align X (Center Screen horizontally)", auto_x)
        if cx then auto_x = vx end

        local cy, vy = imgui.checkbox("Auto-Align Y (Override Vertical Height)", auto_y)
        if cy then auto_y = vy end
        if auto_y then
            local ty, t_vy = imgui.slider_float("  Target Y (Vertical Height)", target_y, -0.3, 0.3)
            if ty then target_y = t_vy end
        end

        local cz, vz = imgui.checkbox("Auto-Align Z (Override Distance)", auto_z)
        if cz then auto_z = vz end
        if auto_z then
            local tz, t_vz = imgui.slider_float("  Target Z (Distance from Cam)", target_z, -0.5, 0.5)
            if tz then target_z = t_vz end
        end
        
        local cs, vs = imgui.slider_float("Transition Speed", smooth_speed, 1.0, 30.0)
        if cs then smooth_speed = vs end
    end
end)
