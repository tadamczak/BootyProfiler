-- Discovery-only provenance; no function is executed to inspect its source.
local P = BootyProfiler
local Source = {}
P.FunctionSource = Source

local MAX_DUMP_BYTES, MAX_SOURCE_BYTES = 262144, 1024
local MAX_SHAPE_CODE, MAX_SHAPE_ITEMS, MAX_SHAPE_DEPTH = 2048, 4096, 16
local function UsableSource(value)
    return type(value) == "string" and string.len(value) > 0
        and string.len(value) <= MAX_SOURCE_BYTES and not string.find(value, "\000", 1, true)
end

local function ReadSize(value, first, count, endian, limit)
    local result = 0
    for index = 1, count do
        local at = endian == 1 and first + count - index or first + index - 1
        local byte = string.byte(value, at)
        if not byte then return nil end
        result = result * 256 + byte
        if result > limit then return nil end
    end
    return result
end

-- Official Lua5.0 ldump.c header followed by the root Proto source string.
-- Never search arbitrary bytecode constants for something resembling a path.
local function DumpSource(value)
    if type(value) ~= "string" or string.len(value) > MAX_DUMP_BYTES then return nil end
    if string.sub(value, 1, 4) ~= "\027Lua" or string.byte(value, 5) ~= 80 then return nil end
    local endian, sizeT = string.byte(value, 6), string.byte(value, 8)
    if endian ~= 0 and endian ~= 1 then return nil end
    if sizeT ~= 4 and sizeT ~= 8 then return nil end
    if string.byte(value, 7) ~= 4 or string.byte(value, 9) ~= 4
        or string.byte(value, 10) ~= 6 or string.byte(value, 11) ~= 8
        or string.byte(value, 12) ~= 9 or string.byte(value, 13) ~= 9
        or string.byte(value, 14) ~= 8 then return nil end
    local first = 23
    local length = ReadSize(value, first, sizeT, endian, MAX_SOURCE_BYTES + 1)
    if not length or length < 2 then return nil end
    first = first + sizeT
    local last = first + length - 1
    -- Source terminator, lineDefined, four root fields and six vector counts.
    if last + 32 > string.len(value) or string.byte(value, last) ~= 0 then return nil end
    local source = string.sub(value, first, last - 1)
    if not UsableSource(source) then return nil end
    if not ReadSize(value, last + 1, 4, endian, 2147483647) then return nil end
    local parameters = string.byte(value, last + 6)
    local isVararg, maxStack = string.byte(value, last + 7), string.byte(value, last + 8)
    if (isVararg ~= 0 and isVararg ~= 1) or not maxStack or maxStack < 1
        or parameters > maxStack then return nil end
    return source, last + 1, endian, sizeT
end

-- Read-only Lua 5.0 prototype metadata. A wrapper is specialized only when all
-- reachable returns have the same fixed arity and the original is not vararg.
-- Native XML chunks use this same official format; no bytecode is executed.
local function CallShape(value, first, endian, sizeT)
    local cursor, items = first, 0
    local function Integer(size, maximum)
        local number = ReadSize(value, cursor, size, endian, maximum)
        if number == nil then return nil end
        cursor = cursor + size
        return number
    end
    local function Skip(size)
        if size < 0 or cursor + size - 1 > string.len(value) then return false end
        cursor = cursor + size; return true
    end
    local function String()
        local size = Integer(sizeT, MAX_DUMP_BYTES)
        return size ~= nil and Skip(size)
    end
    local function Count()
        local count = Integer(4, MAX_SHAPE_ITEMS)
        if count == nil or items + count > MAX_SHAPE_ITEMS then return nil end
        items = items + count; return count
    end
    local rootCode, parameters, vararg
    local Parse
    Parse = function(depth, root)
        if depth > MAX_SHAPE_DEPTH then return false end
        if not root and not String() then return false end
        if Integer(4, 2147483647) == nil then return false end
        if cursor + 3 > string.len(value) then return false end
        if root then parameters, vararg = string.byte(value, cursor + 1), string.byte(value, cursor + 2) end
        cursor = cursor + 4
        local count = Count(); if count == nil or not Skip(count * 4) then return false end
        count = Count(); if count == nil then return false end
        for index = 1, count do if not String() or not Skip(8) then return false end end
        count = Count(); if count == nil then return false end
        for index = 1, count do if not String() then return false end end
        count = Count(); if count == nil then return false end
        for index = 1, count do
            local kind = Integer(1, 255)
            if kind == 3 then if not Skip(8) then return false end
            elseif kind == 4 then if not String() then return false end
            elseif kind ~= 0 then return false end
        end
        count = Count(); if count == nil then return false end
        for index = 1, count do if not Parse(depth + 1, false) then return false end end
        count = Count(); if count == nil or count > MAX_SHAPE_CODE then return false end
        if root then
            rootCode = {}
            for index = 1, count do
                local instruction = Integer(4, 4294967295)
                if instruction == nil then return false end
                rootCode[index] = instruction
            end
        elseif not Skip(count * 4) then return false end
        return true
    end
    if not Parse(1, true) or cursor ~= string.len(value) + 1 or vararg ~= 0 then return nil end
    local size, pending, seen, resultCount = table.getn(rootCode), { 1 }, {}, nil
    local function Queue(pc)
        if pc < 1 or pc > size then return false end
        if not seen[pc] then seen[pc] = true; table.insert(pending, pc) end
        return true
    end
    seen[1] = true
    while table.getn(pending) > 0 do
        local pc = table.remove(pending)
        local instruction = rootCode[pc]
        if not instruction then return nil end
        local opcode = instruction - math.floor(instruction / 64) * 64
        local b = math.floor(instruction / 32768); b = b - math.floor(b / 512) * 512
        local c = math.floor(instruction / 64); c = c - math.floor(c / 512) * 512
        local bx = math.floor(instruction / 64); bx = bx - math.floor(bx / 262144) * 262144
        if opcode == 27 then
            if b == 0 or (resultCount ~= nil and resultCount ~= b - 1) then return nil end
            resultCount = b - 1
        elseif opcode == 26 or opcode >= 34 then
            -- Tail calls have unknown arity; closures carry binding words.
            return nil
        elseif opcode == 20 or opcode == 30 then
            if not Queue(pc + 1 + bx - 131071) then return nil end
        elseif opcode == 28 then
            if not Queue(pc + 1) or not Queue(pc + 1 + bx - 131071) then return nil end
        elseif opcode == 21 or opcode == 22 or opcode == 23 or opcode == 24 or opcode == 29 then
            if not Queue(pc + 1) or not Queue(pc + 2) then return nil end
        elseif opcode == 2 and c ~= 0 then
            if not Queue(pc + 2) then return nil end
        elseif not Queue(pc + 1) then return nil end
    end
    if resultCount == nil then return nil end
    return { parameters = parameters, results = resultCount, proven = true }
end

function Source.Get(callback, includeCallShape)
    if type(callback) ~= "function" then return nil, "unavailable", "invalid-function" end
    local inspect = type(debug) == "table" and rawget(debug, "getinfo")
    local authoritative
    if type(inspect) == "function" then
        local ok, info = pcall(inspect, callback, "S")
        local source = ok and type(info) == "table" and rawget(info, "source")
        if UsableSource(source) then
            if not includeCallShape then return source, "debug.getinfo" end
            authoritative = source
        end
    end
    if type(string.dump) == "function" then
        -- Stock Lua5.0 rejects C functions and closures with captured upvalues.
        -- string.dump allocates a complete accepted function before the size
        -- check. The caller must budget/cache discovery; never call this hot.
        local ok, value = pcall(string.dump, callback)
        if not ok then
            if authoritative then return authoritative, "debug.getinfo" end
            return nil, "unavailable", "dump-rejected"
        end
        local source, first, endian, sizeT = DumpSource(value)
        if source then
            local shape = includeCallShape and CallShape(value, first, endian, sizeT) or nil
            return authoritative or source, authoritative and "debug.getinfo" or "Lua5.0 dump", nil, shape
        end
        if authoritative then return authoritative, "debug.getinfo" end
        return nil, "unavailable", "unsupported-dump"
    end
    if authoritative then return authoritative, "debug.getinfo" end
    return nil, "unavailable", "no-source-api"
end
