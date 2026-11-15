-- CloudKeyTao：次选键改为分号。
-- 有候选菜单时按 ; 提交当前页的第二项；无菜单时交回后续处理。
local KEY = "semicolon"
local kAccepted = 1
local kNoop = 2

local function processor(key_event, env)
    if key_event:release() or key_event:repr() ~= KEY then
        return kNoop
    end

    local context = env.engine.context
    local segment = context.composition:back()
    if not segment or not context:get_selected_candidate() then
        return kNoop
    end

    local page_size = env.engine.schema.page_size
    local page_start = math.floor(segment.selected_index / page_size) * page_size
    if context:select(page_start + 1) then
        context:commit()
        return kAccepted
    end

    context:commit()
    return kAccepted
end

return { func = processor }
