-- Lune test: exercises the BipolarFlags Store core outside Roblox -- versioned
-- apply, typed getters, the onStart/onShutdown/onChange lifecycle, and stale
-- version rejection. The HTTP polling + Bipolar replication in init.luau need
-- Roblox and aren't covered here.
-- Run: lune run tests/flags.test.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local function loadModule(path: string, env: { [any]: any })
	local source = fs.readFile(path)
	local fn = luau.load(source, { environment = env, injectGlobals = true, debugName = path })
	return fn()
end

-- Store requires nothing (pure core); give it an empty env.
local Store = loadModule("src/shared/BipolarFlags/Store.luau", {})

local passed = 0
local function check(name: string, cond: boolean)
	assert(cond, "FAILED: " .. name)
	passed += 1
	print("  ok - " .. name)
end

print("Typed getters + defaults:")
do
	local s = Store.new()
	s:apply({ on = true, rate = 2.5, name = "alpha", nested = { a = 1 } }, 1)
	check("getBool reads a boolean", s:getBool("on", false) == true)
	check("getNumber reads a number", s:getNumber("rate", 0) == 2.5)
	check("getString reads a string", s:getString("name", "") == "alpha")
	check("get returns table value", (s:get("nested") :: any).a == 1)
	check("missing key falls back to default", s:getNumber("nope", 7) == 7)
	check("wrong-type read falls back to default", s:getBool("rate", false) == false)
	check("version is tracked", s.version == 1)
end

print("Lifecycle: first apply runs onStart, not onShutdown:")
do
	local s = Store.new()
	local starts, shutdowns = {}, {}
	s:onStart(function(_flags, v)
		table.insert(starts, v)
	end)
	s:onShutdown(function(_flags, v)
		table.insert(shutdowns, v)
	end)
	s:apply({ a = 1 }, 1)
	check("onStart fired on first activation", #starts == 1 and starts[1] == 1)
	check("onShutdown did NOT fire on first activation", #shutdowns == 0)
end

print("Lifecycle: hot-reload runs shutdown(old) then start(new):")
do
	local s = Store.new()
	local order = {}
	s:apply({ a = 1 }, 1)
	s:onStart(function(_f, v)
		table.insert(order, "start:" .. v)
	end)
	s:onShutdown(function(_f, v)
		table.insert(order, "shutdown:" .. v)
	end)
	-- onStart fires immediately for the already-active set (v1)...
	check("onStart fires immediately when already active", order[1] == "start:1")
	table.clear(order)
	-- ...then a new version retires the old, then starts the new.
	s:apply({ a = 2 }, 2)
	check("hot-reload order is shutdown(old) then start(new)", order[1] == "shutdown:1" and order[2] == "start:2")
end

print("onChange: per-key and any-key:")
do
	local s = Store.new()
	local keyHits, anyHits = {}, {}
	s:onChange("flag", function(new, old)
		table.insert(keyHits, { new = new, old = old })
	end)
	s:onChange(function(new, old, key)
		table.insert(anyHits, key)
	end)
	s:apply({ flag = true, other = 1 }, 1) -- both new vs the empty default
	check("any-key handler saw both new keys", #anyHits == 2)
	check("per-key handler fired once with new=true, old=nil", #keyHits == 1 and keyHits[1].new == true and keyHits[1].old == nil)

	table.clear(keyHits)
	table.clear(anyHits)
	s:apply({ flag = false, other = 1 }, 2) -- only `flag` changed
	check("only the changed key notifies per-key", #keyHits == 1 and keyHits[1].new == false and keyHits[1].old == true)
	check("any-key handler saw exactly one change", #anyHits == 1 and anyHits[1] == "flag")
end

print("Stale / duplicate versions are ignored:")
do
	local s = Store.new()
	local applies = 0
	s:onStart(function()
		applies += 1
	end)
	s:apply({ a = 1 }, 5)
	s:apply({ a = 999 }, 5) -- same version -> ignored
	s:apply({ a = 999 }, 3) -- lower version -> ignored
	check("duplicate version did not re-activate", applies == 1)
	check("active value unchanged by stale applies", s:getNumber("a", 0) == 1)
	check("version held at the highest activated", s.version == 5)
end

print("seed: defaults before first sync, diffed away on activation:")
do
	local s = Store.new()
	s:seed({ a = 1, b = 2 })
	check("seeded value readable before any apply", s:getNumber("a", 0) == 1)
	check("seed does not mark the store active", s.started == false)
	local changes = s:apply({ a = 1, b = 3, c = 4 }, 1) -- a unchanged, b changed, c added
	local changed = {}
	for _, c in changes do
		changed[c.key] = true
	end
	check("unchanged seeded key is NOT reported", changed.a == nil)
	check("changed + added keys are reported", changed.b == true and changed.c == true)
end

print(string.format("\nAll %d checks passed.", passed))
