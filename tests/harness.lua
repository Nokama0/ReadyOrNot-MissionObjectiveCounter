-- tests/harness.lua
-- Minimal assertions so the suite needs no external dependency.
local H = { passed = 0, failed = 0, failures = {} }

local function serialise(v)
    -- Tag non-table values with their type so, for example, the number 5
    -- and the string "5" serialise to distinct forms. Without this, H.eq
    -- would compare their tostring() output and report them as equal.
    if type(v) ~= "table" then return type(v) .. ":" .. tostring(v) end
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = serialise(v[i]) end
    local keys = {}
    for k in pairs(v) do
        if type(k) ~= "number" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. serialise(v[k])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end
H.serialise = serialise

function H.eq(name, actual, expected)
    local a, e = serialise(actual), serialise(expected)
    if a == e then
        H.passed = H.passed + 1
    else
        H.failed = H.failed + 1
        H.failures[#H.failures + 1] = string.format(
            "%s\n     expected: %s\n     actual:   %s", name, e, a)
    end
end

function H.report()
    for _, f in ipairs(H.failures) do print("FAIL " .. f) end
    print(string.format("%d passed, %d failed", H.passed, H.failed))
    if H.failed > 0 then os.exit(1) end
end

return H
