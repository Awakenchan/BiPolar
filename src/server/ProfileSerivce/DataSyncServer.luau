--@awaken here read blows
-- DataSync layer. Lets you replicate arbitrary profile keys to the client without writing a bespoke
-- remote for each one. It COMPLEMENTS your existing InventorySync / UnlockSync / HotbarSync remotes —
-- it does not replace them. Use it for plain scalar/table fields you want mirrored cheaply.
--
-- Two packets (defined inline, the same way the reference defined Packet("DataSyncRequest")). The CLIENT
-- must require Shared.Packet and define the same two names to listen — see README "Client listener".
--
-- Wiring (in DataManager, after Profiles is populated):
--   local DataSync = require(script.Parent.DataSyncServer)
--   DataSync.Bind(function(player) return DataManager.GetData(player) end)
--   DataSync.Start()
-- On join, after the profile is ready:
--   DataSync.PushSnapshot(player)                     -- replicate every key in ReplicatedKeys
-- When a replicated field changes:
--   DataSync.MarkDirty(player, "Stars")               -- batched + flushed on the next Heartbeat tick
-- On leave:
--   DataSync.Clear(player)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packet = require(Shared:WaitForChild("Packet"))

local Str = Packet.String
local Any = Packet.Any

local DataSnapshot = Packet("DataSnapshot", Any)     
local DataPush = Packet("DataPush", Str, Any)         

local ReplicatedKeys: { string } = {
	"TotalRolls",
	"Stars",
	"StarsUsed",
	"Luck",
	"BorderLuck",
	"BattleSpeed",
	"TopFloor",
	"InfiniteFloorsCleared",
	"EquippedCharm",
	"EquippedRelic",
	"BannerSummons",
}

local DataSync = {}

local getData: ((Player) -> any)? = nil
local dirty: { [Player]: { [string]: boolean } } = {}
local started = false
local flushInterval = 0.1
local accumulator = 0

function DataSync.Bind(resolver: (Player) -> any)
	getData = resolver
end

-- Override / inspect the replicated key allow-list.
function DataSync.SetReplicatedKeys(keys: { string })
	ReplicatedKeys = keys
end

function DataSync.GetReplicatedKeys(): { string }
	return ReplicatedKeys
end

local function valueFor(player: Player, key: string): any
	if not getData then
		return nil
	end
	local data = getData(player)
	if type(data) ~= "table" then
		return nil
	end
	return data[key]
end

function DataSync.PushSnapshot(player: Player, keys: { string }?)
	if not player or not player.Parent then
		return
	end
	local list = keys or ReplicatedKeys
	local snapshot: { [string]: any } = {}
	for _, key in ipairs(list) do
		snapshot[key] = valueFor(player, key)
	end
	DataSnapshot:FireClient(player, snapshot)
end

-- Replicate a single key right now.
function DataSync.Push(player: Player, key: string)
	if not player or not player.Parent then
		return
	end
	DataPush:FireClient(player, key, valueFor(player, key))
end

-- Queue a key for replication on the next Heartbeat flush (coalesces rapid changes).
function DataSync.MarkDirty(player: Player, key: string)
	local set = dirty[player]
	if not set then
		set = {}
		dirty[player] = set
	end
	set[key] = true
end

function DataSync.Clear(player: Player)
	dirty[player] = nil
end

local function flush()
	for player, set in pairs(dirty) do
		if player.Parent then
			for key in pairs(set) do
				DataPush:FireClient(player, key, valueFor(player, key))
			end
		end
		dirty[player] = nil
	end
end

function DataSync.Start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < flushInterval then
			return
		end
		accumulator = 0
		flush()
	end)
end

return DataSync
