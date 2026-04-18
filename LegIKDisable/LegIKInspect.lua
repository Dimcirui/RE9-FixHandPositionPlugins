-- LegIKInspect.lua  v3
-- Finds anim.AnimIkLeg, then iterates LegParams[] and dumps
-- all fields of each LegParam element.
-- Output: reframework/data/LHandIKFix/leg_ik_inspect.json

local OUTPUT_FILE = "LHandIKFix/leg_ik_inspect.json"
local done = false

local function dump_fields(obj)
    if not obj then return nil end
    local ok_td, td = pcall(obj.get_type_definition, obj)
    if not ok_td or not td then return { __type = "<unknown>" } end

    local result = { __type = td:get_full_name() }
    local ok_fl, fields = pcall(td.get_fields, td)
    if not ok_fl or not fields then return result end

    for _, field in ipairs(fields) do
        local ok_n, fname = pcall(field.get_name, field)
        if not ok_n then goto continue end
        local ok_v, val = pcall(field.get_data, field, obj)
        if not ok_v then
            result[fname] = "<error>"
        elseif val == nil then
            result[fname] = nil
        elseif type(val) == "boolean" or type(val) == "number" or type(val) == "string" then
            result[fname] = val
        elseif type(val) == "userdata" then
            local ok_ct, ctd = pcall(val.get_type_definition, val)
            result[fname] = (ok_ct and ctd) and ("<" .. ctd:get_full_name() .. ">") or "<userdata>"
        else
            result[fname] = tostring(val)
        end
        ::continue::
    end
    return result
end

local function find_and_inspect(go)
    local acb = go:call("getComponent(System.Type)", sdk.typeof("anim.AnimationControllerBehavior"))
    if not acb then return nil, "no AnimationControllerBehavior" end
    local ac = acb:get_type_definition():get_field("AnimationController"):get_data(acb)
    if not ac then return nil, "no AnimationController" end
    local ab = ac:get_type_definition():get_field("AnimationBases"):get_data(ac)
    if not ab then return nil, "no AnimationBases" end
    local ok, count = pcall(ab.call, ab, "get_Count")
    if not ok or not count then return nil, "no Count" end

    for i = 0, count - 1 do
        local ok_i, item = pcall(ab.call, ab, "get_Item(System.Int32)", i)
        if ok_i and item then
            local ok_t, td = pcall(item.get_type_definition, item)
            if ok_t and td and td:get_full_name() == "anim.AnimIkLeg" then
                -- Found the component — now inspect LegParams array
                local result = { __type = "anim.AnimIkLeg", LegParams = {} }
                local ok_lf, lf = pcall(td.get_field, td, "LegParams")
                if not ok_lf or not lf then return result, "LegParams field not found" end
                local ok_arr, arr = pcall(lf.get_data, lf, item)
                if not ok_arr or not arr then return result, "LegParams data nil" end

                local ok_sz, sz = pcall(arr.get_size, arr)
                if not ok_sz then
                    ok_sz, sz = pcall(arr.call, arr, "get_Length")
                end
                if ok_sz and sz then
                    for j = 0, sz - 1 do
                        local ok_el, el = pcall(arr.call, arr, "get_Item(System.Int32)", j)
                        if ok_el and el then
                            local entry = dump_fields(el)
                            -- Also expand IK field (anim.AnimIKHelper.IKInfo)
                            local ok_etd, etd = pcall(el.get_type_definition, el)
                            if ok_etd and etd then
                                local ok_ikf, ikf = pcall(etd.get_field, etd, "IK")
                                if ok_ikf and ikf then
                                    local ok_ikv, ikv = pcall(ikf.get_data, ikf, el)
                                    if ok_ikv and ikv then
                                        entry["IK"] = dump_fields(ikv)
                                    end
                                end
                            end
                            result.LegParams[tostring(j)] = entry
                        else
                            result.LegParams[tostring(j)] = "<error getting element>"
                        end
                    end
                else
                    result.LegParams["__note"] = "could not get array size"
                end

                return result, nil
            end
        end
    end
    return nil, "anim.AnimIkLeg not found"
end

-- Collect type metadata (value_type, field offsets)
local function type_meta()
    local out = {}
    for _, tname in ipairs({ "anim.AnimIkLeg", "anim.AnimIkLeg.LegParam", "anim.AnimIKHelper.IKInfo" }) do
        local td = sdk.find_type_definition(tname)
        if td then
            local entry = { is_value_type = td:is_value_type(), fields = {} }
            local ok_fl, fields = pcall(td.get_fields, td)
            if ok_fl and fields then
                for _, f in ipairs(fields) do
                    local ok_n, fname = pcall(f.get_name, f)
                    local ok_o, foff  = pcall(f.get_offset_from_base, f)
                    if ok_n and ok_o then
                        entry.fields[fname] = foff
                    end
                end
            end
            out[tname] = entry
        else
            out[tname] = { error = "type not found" }
        end
    end
    return out
end

re.on_frame(function()
    if done then return end

    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return end
    local scene = sdk.call_native_func(sm,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end

    local output = { type_meta = type_meta() }
    local any_found = false

    for _, target in ipairs({ { name = "Grace", go_name = "cp_A100" }, { name = "Leon", go_name = "cp_A000" } }) do
        local go = scene:call("findGameObject(System.String)", target.go_name)
        if go then
            local data, err = find_and_inspect(go)
            if data then
                output[target.name] = data
                any_found = true
            else
                output[target.name] = { error = err }
            end
        else
            output[target.name] = { error = "GameObject not in scene" }
        end
    end

    if any_found then
        json.dump_file(OUTPUT_FILE, output)
        log.info("[LegIKInspect] Saved to " .. OUTPUT_FILE)
        done = true
    end
end)

re.on_draw_ui(function()
    if imgui.collapsing_header("Leg IK Inspect") then
        if done then
            imgui.text("Done! Check: reframework/data/" .. OUTPUT_FILE)
        else
            imgui.text("Waiting for Grace or Leon to appear in scene...")
        end
        if imgui.button("Reset (run again)") then
            done = false
        end
    end
end)

log.info("[LegIKInspect] Loaded.")
