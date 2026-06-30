--!strict

export type FlagValue = boolean | number | string | { [any]: any }
export type FlagSet = { [string]: FlagValue }

export type Change = {
	key: string,
	old: FlagValue?,
	new: FlagValue?,
}

type Lifecycle = (flags: FlagSet, version: number) -> ()
type OnChange = (new: FlagValue?, old: FlagValue?, key: string) -> ()

local Store = {}
Store.__index = Store

Store.errorHandler = nil :: ((string) -> ())?

export type Store = typeof(setmetatable(
	{} :: {
		flags: FlagSet,
		version: number,
		started: boolean,
		startHandlers: { Lifecycle },
		shutdownHandlers: { Lifecycle },
		anyChangeHandlers: { OnChange },
		keyChangeHandlers: { [string]: { OnChange } },
	},
	Store
))

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function copy(t: FlagSet): FlagSet
	local out: FlagSet = {}
	for k, v in t do
		out[k] = v
	end
	return out
end

local function diff(old: FlagSet, new: FlagSet): { Change }
	local out: { Change } = {}
	local seen: { [string]: boolean } = {}
	for k, v in new do
		seen[k] = true
		if not deepEqual(old[k], v) then
			table.insert(out, { key = k, old = old[k], new = v })
		end
	end
	for k, v in old do
		if not seen[k] then
			table.insert(out, { key = k, old = v, new = nil })
		end
	end
	return out
end

local function safe(fn: (...any) -> (), ...: any)
	local ok, err = pcall(fn, ...)
	if not ok and Store.errorHandler then
		Store.errorHandler(tostring(err))
	end
end

function Store.new(): Store
	return setmetatable({
		flags = {},
		version = 0,
		started = false,
		startHandlers = {},
		shutdownHandlers = {},
		anyChangeHandlers = {},
		keyChangeHandlers = {},
	}, Store)
end

function Store.get(self: Store, key: string, default: FlagValue?): FlagValue?
	local v = self.flags[key]
	if v == nil then
		return default
	end
	return v
end

function Store.getBool(self: Store, key: string, default: boolean): boolean
	local v = self.flags[key]
	return if type(v) == "boolean" then v else default
end

function Store.getNumber(self: Store, key: string, default: number): number
	local v = self.flags[key]
	return if type(v) == "number" then v else default
end

function Store.getString(self: Store, key: string, default: string): string
	local v = self.flags[key]
	return if type(v) == "string" then v else default
end

function Store.all(self: Store): FlagSet
	return copy(self.flags)
end

function Store.seed(self: Store, defaults: FlagSet)
	if self.started then
		return
	end
	self.flags = copy(defaults)
end

function Store.apply(self: Store, newFlags: FlagSet, version: number): { Change }
	if self.started and version <= self.version then
		return {}
	end

	local changes = diff(self.flags, newFlags)
	local oldFlags = self.flags
	local oldVersion = self.version
	local wasStarted = self.started

	if wasStarted then
		for _, h in self.shutdownHandlers do
			safe(h, oldFlags, oldVersion)
		end
	end

	self.flags = copy(newFlags)
	self.version = version
	self.started = true
	for _, h in self.startHandlers do
		safe(h, self.flags, version)
	end

	for _, c in changes do
		local list = self.keyChangeHandlers[c.key]
		if list then
			for _, h in list do
				safe(h, c.new, c.old, c.key)
			end
		end
		for _, h in self.anyChangeHandlers do
			safe(h, c.new, c.old, c.key)
		end
	end

	return changes
end

function Store.onStart(self: Store, handler: Lifecycle): () -> ()
	table.insert(self.startHandlers, handler)
	if self.started then
		safe(handler, self.flags, self.version)
	end
	return function()
		local i = table.find(self.startHandlers, handler)
		if i then
			table.remove(self.startHandlers, i)
		end
	end
end

function Store.onShutdown(self: Store, handler: Lifecycle): () -> ()
	table.insert(self.shutdownHandlers, handler)
	return function()
		local i = table.find(self.shutdownHandlers, handler)
		if i then
			table.remove(self.shutdownHandlers, i)
		end
	end
end

function Store.onChange(self: Store, keyOrHandler: string | OnChange, handler: OnChange?): () -> ()
	if type(keyOrHandler) == "function" then
		local h = keyOrHandler
		table.insert(self.anyChangeHandlers, h)
		return function()
			local i = table.find(self.anyChangeHandlers, h)
			if i then
				table.remove(self.anyChangeHandlers, i)
			end
		end
	end

	local key = keyOrHandler
	local h = handler :: OnChange
	local list = self.keyChangeHandlers[key]
	if not list then
		list = {}
		self.keyChangeHandlers[key] = list
	end
	table.insert(list, h)
	return function()
		local i = table.find(list, h)
		if i then
			table.remove(list, i)
		end
	end
end

return Store
