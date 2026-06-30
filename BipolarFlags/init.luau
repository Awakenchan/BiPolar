--!strict

local RunService = game:GetService("RunService")

local Store = require(script.Store)
local Bipolar = require(script.Parent.BiPolar)

local IS_SERVER = RunService:IsServer()

export type FlagValue = Store.FlagValue
export type FlagSet = Store.FlagSet
export type Config = {
	Endpoint: string,
	Secret: string?,
	SecretName: string?,
	Interval: number?,
	Defaults: FlagSet?,
}

Store.errorHandler = function(msg: string)
	warn("[BipolarFlags] handler error:", msg)
end

local store = Store.new()

local t = Bipolar.types
local FlagSync = Bipolar.define("__BipolarFlags", {
	version = t.uint,
	flags = t.any,
}, { direction = Bipolar.Direction.ServerToClient })

local Flags = {}

function Flags.get(key: string, default: FlagValue?): FlagValue?
	return store:get(key, default)
end
function Flags.getBool(key: string, default: boolean): boolean
	return store:getBool(key, default)
end
function Flags.getNumber(key: string, default: number): number
	return store:getNumber(key, default)
end
function Flags.getString(key: string, default: string): string
	return store:getString(key, default)
end
function Flags.all(): FlagSet
	return store:all()
end
function Flags.version(): number
	return store.version
end
function Flags.onStart(handler: (flags: FlagSet, version: number) -> ()): () -> ()
	return store:onStart(handler)
end
function Flags.onShutdown(handler: (flags: FlagSet, version: number) -> ()): () -> ()
	return store:onShutdown(handler)
end
function Flags.onChange(
	keyOrHandler: string | (new: FlagValue?, old: FlagValue?, key: string) -> (),
	handler: ((new: FlagValue?, old: FlagValue?, key: string) -> ())?
): () -> ()
	return store:onChange(keyOrHandler, handler)
end

local started = false

local function broadcast()
	FlagSync:fireAllClients({ version = store.version, flags = store:all() })
end

local function syncOnce(config: Config)
	local HttpService = game:GetService("HttpService")

	local headers: { [string]: any } = { ["Content-Type"] = "application/json" }
	if config.SecretName then
		headers["x-game-secret"] = HttpService:GetSecret(config.SecretName)
	elseif config.Secret then
		headers["x-game-secret"] = config.Secret
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = config.Endpoint .. "/flags/sync",
			Method = "POST",
			Headers = headers,
			Body = HttpService:JSONEncode({ version = store.version }),
		})
	end)
	if not ok or not response.Success then
		return
	end

	local decoded: any = nil
	local decodeOk = pcall(function()
		decoded = HttpService:JSONDecode(response.Body)
	end)
	if not decodeOk or type(decoded) ~= "table" then
		return
	end
	if type(decoded.flags) ~= "table" or type(decoded.version) ~= "number" then
		return
	end

	local before = store.version
	store:apply(decoded.flags, decoded.version)
	if store.version ~= before then
		broadcast()
	end
end

function Flags.Start(config: Config)
	assert(IS_SERVER, "BipolarFlags.Start must run on the server")
	assert(not started, "BipolarFlags already started")
	assert(config.Endpoint, "BipolarFlags.Start needs an Endpoint")
	assert(config.Secret or config.SecretName, "BipolarFlags.Start needs Secret or SecretName")
	started = true

	if config.Defaults then
		store:seed(config.Defaults)
	end

	local Players = game:GetService("Players")
	Players.PlayerAdded:Connect(function(player: Player)
		if store.started then
			FlagSync:fireClient(player, { version = store.version, flags = store:all() })
		end
	end)

	local interval = config.Interval or 5
	task.spawn(function()
		while true do
			syncOnce(config)
			task.wait(interval)
		end
	end)
end

if not IS_SERVER then
	FlagSync:listen(function(data)
		if type(data) == "table" and type(data.flags) == "table" and type(data.version) == "number" then
			store:apply(data.flags, data.version)
		end
	end)
end

return Flags
