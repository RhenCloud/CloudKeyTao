local M = {}

local function file_stamp(path)
  local pipe = io.popen("stat -c %Y " .. string.format("%q", path) .. " 2>/dev/null")
  if not pipe then
    return "missing"
  end
  local stamp = pipe:read("*l") or "missing"
  pipe:close()
  return stamp
end

local function load(path)
  local index = {}
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  for line in file:lines() do
    local text, code, weight = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
    weight = weight and tonumber(weight)
    if text and code and weight and weight >= 0 then
      local bucket = index[code]
      if not bucket then
        bucket = {}
        index[code] = bucket
      end
      bucket[#bucket + 1] = {
        text = text,
        weight = weight,
      }
    end
  end
  file:close()
  return index
end

function M.init(env)
  env.path = rime_api.get_user_data_dir() .. "/cloudkeytao-custom-phrase.txt"
  env.stamp = ""
  env.index = {}
end

function M.func(input, seg, env)
  local stamp = file_stamp(env.path)
  if stamp ~= env.stamp then
    local index = load(env.path)
    if index then
      env.index = index
      env.stamp = stamp
    end
  end

  for _, entry in ipairs(env.index[input] or {}) do
    local candidate = Candidate("custom_phrase", seg.start, seg._end, entry.text, "")
    candidate.quality = entry.weight
    yield(candidate)
  end
end

return M
