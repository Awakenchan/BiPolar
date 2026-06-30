--!strict

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local BitBuffer = require(script.Parent.BitBuffer)
local Profiler = require(script.Parent.Profiler)
local Types = require(script.Parent.Types)

local IS_SERVER = RunService:IsServer()

local FOLDER_NAME = "BipolarNetworking"
local READY_ATTR = "__BipolarReady__"
local SEED_ATTR = "__BipolarSeed__"
local ID_BYTES_ATTR = "__BipolarIdBytes__"
local TAG_REQUEST = 0
local TAG_RESPONSE = 1
local REQUEST_TIMEOUT = 10
local KEY_SIZE = 256

export type SecurityConfig = {

	auto: boolean?,
	factor: number?,
	warmupSeconds: number?,
	floorPacketsPerSecond: number?,
	floorBytesPerSecond: number?,
	hardPacketsPerSecond: number?,
	hardBytesPerSecond: number?,

	maxBufferBytes: number?,
	maxStrikes: number?,
	kick: boolean?,

	maxPacketsPerSecond: number?,
	maxBytesPerSecond: number?,
}

export type HookInfo = {
	name: string,
	kind: string,
	dir: string,
	player: Player?,
	value: any,
}
export type Hook = (HookInfo) -> boolean?

export type Packet = {
	name: string,
	kind: string,
	direction: string,
	unreliable: boolean,
	type: Types.BipolarType?,
	requestType: Types.BipolarType?,
	responseType: Types.BipolarType?,
	handlers: { (...any) -> () },
	invokeHandler: ((...any) -> any)?,
	wireId: number?,

	rateLimit: number?,
	inboundHooks: { Hook }?,
	outboundHooks: { Hook }?,
}

type Channel = { reliable: BitBuffer.Writer, unreliable: BitBuffer.Writer }

local function newChannel(): Channel
	return { reliable = BitBuffer.Writer.new(64), unreliable = BitBuffer.Writer.new(64) }
end

local Kernel = {}

local packets: { Packet } = {}
local packetsByName: { [string]: Packet } = {}
local wireToPacket: { [number]: Packet } = {}

local ready = false
local building = false
local waiters: { thread } = {}
local masterSeed = 0
local integrateLate: (Packet) -> ()

local nextRequestId = 0
local pending: { [number]: thread } = {}

local clientOut: Channel = newChannel()
local serverOut: { [Player]: Channel } = {}

local scrambleKey = buffer.create(KEY_SIZE)

local idBytes = 2

local function writeWireId(w: BitBuffer.Writer, id: number)
	if idBytes == 1 then
		w:u8(id)
	else
		w:u16(id)
	end
end

local function readWireId(reader: BitBuffer.Reader): number
	if idBytes == 1 then
		return reader:u8()
	end
	return reader:u16()
end

local security = {
	auto = true,
	factor = 8,
	warmupSeconds = 5,
	floorPacketsPerSecond = 1000,
	floorBytesPerSecond = 1048576,
	hardPacketsPerSecond = 4000,
	hardBytesPerSecond = 4194304,
	maxBufferBytes = 65536,
	maxStrikes = 8,
	kick = false,

	maxPacketsPerSecond = 240,
	maxBytesPerSecond = 131072,
}
type RateInfo = {
	second: number,
	packets: number,
	bytes: number,
	strikes: number,
	peakPackets: number,
	peakBytes: number,
	joinSecond: number,
	over: boolean,
}
local rateByPlayer: { [Player]: RateInfo } = {}

local packetRateByPlayer: { [Player]: { [Packet]: { sec: number, n: number } } } = {}

local function allowPacket(packet: Packet, player: Player?): boolean
	local limit = packet.rateLimit
	if not limit or not player then
		return true
	end
	local now = os.clock() // 1
	local byPacket = packetRateByPlayer[player]
	if not byPacket then
		byPacket = {}
		packetRateByPlayer[player] = byPacket
	end
	local slot = byPacket[packet]
	if not slot or slot.sec ~= now then
		slot = { sec = now, n = 1 }
		byPacket[packet] = slot
		return 1 <= limit
	end
	slot.n += 1
	return slot.n <= limit
end

local remotesFolder: Instance
local reliableRemote: RemoteEvent
local unreliableRemote: UnreliableRemoteEvent

function Kernel.setSecurity(cfg: SecurityConfig)
	for key, value in cfg :: { [string]: any } do
		if (security :: { [string]: any })[key] ~= nil then
			(security :: { [string]: any })[key] = value
		end
	end
end

function Kernel.register(packet: Packet)
	assert(not packetsByName[packet.name], `BiPolar: duplicate packet name "{packet.name}"`)
	packetsByName[packet.name] = packet
	table.insert(packets, packet)

	if ready then
		integrateLate(packet)
	end
end

local function packetSeed(name: string): number
	local h = masterSeed % 2147483647
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 2147483647
	end
	return h + 1
end

local function finalizeType(ty: Types.BipolarType?, name: string)
	if ty and ty.finalize then
		ty.finalize(Random.new(packetSeed(name)))
	end
end

local function finalizeOne(packet: Packet)
	finalizeType(packet.type, packet.name)
	finalizeType(packet.requestType, packet.name .. "\1req")
	finalizeType(packet.responseType, packet.name .. "\1res")
end

local function rebuildCodec(seed: number)
	masterSeed = seed
	for _, p in packets do
		finalizeOne(p)
	end
	local keyRng = Random.new(seed + 1)
	for i = 0, KEY_SIZE - 1 do
		buffer.writeu8(scrambleKey, i, keyRng:NextInteger(0, 255))
	end
end

function integrateLate(packet: Packet)
	finalizeOne(packet)
	if IS_SERVER then
		local maxId = if idBytes == 1 then 255 else 65535
		local wire
		repeat
			wire = math.random(0, maxId)
		until not wireToPacket[wire]
		packet.wireId = wire
		wireToPacket[wire] = packet
		remotesFolder:SetAttribute(packet.name, wire)
	else
		local wire = remotesFolder:GetAttribute(packet.name)
		if wire then
			packet.wireId = wire :: number
			wireToPacket[wire :: number] = packet
		else
			local conn: RBXScriptConnection
			conn = remotesFolder:GetAttributeChangedSignal(packet.name):Connect(function()
				local id = remotesFolder:GetAttribute(packet.name)
				if id then
					packet.wireId = id :: number
					wireToPacket[id :: number] = packet
					conn:Disconnect()
				end
			end)
		end
	end
end

local function scramble(buf: buffer)
	local len = buffer.len(buf)
	local wordEnd = len - len % 4
	local i = 0
	while i < wordEnd do
		local k = buffer.readu32(scrambleKey, i % KEY_SIZE)
		buffer.writeu32(buf, i, bit32.bxor(buffer.readu32(buf, i), k))
		i += 4
	end
	while i < len do
		buffer.writeu8(buf, i, bit32.bxor(buffer.readu8(buf, i), buffer.readu8(scrambleKey, i % KEY_SIZE)))
		i += 1
	end
end

local function buildServerProtocol()
	local rng = Random.new()
	idBytes = if #packets <= 255 then 1 else 2
	local maxId = if idBytes == 1 then 255 else 65535
	table.clear(wireToPacket)
	local used: { [number]: boolean } = {}
	for _, p in packets do
		local wire
		repeat
			wire = rng:NextInteger(0, maxId)
		until not used[wire]
		used[wire] = true
		p.wireId = wire
		wireToPacket[wire] = p
		remotesFolder:SetAttribute(p.name, wire)
	end
	local seed = Random.new():NextInteger(1, 2147483646)
	rebuildCodec(seed)
	remotesFolder:SetAttribute(SEED_ATTR, seed)
	remotesFolder:SetAttribute(ID_BYTES_ATTR, idBytes)
	remotesFolder:SetAttribute(READY_ATTR, true)
end

local function buildClientProtocol()
	if remotesFolder:GetAttribute(READY_ATTR) == nil then
		remotesFolder:GetAttributeChangedSignal(READY_ATTR):Wait()
	end
	idBytes = (remotesFolder:GetAttribute(ID_BYTES_ATTR) :: number?) or 2
	table.clear(wireToPacket)
	for _, p in packets do
		local wire = remotesFolder:GetAttribute(p.name)
		assert(
			wire ~= nil,
			`BiPolar: server published no id for "{p.name}" (do the client and server define the same packets?)`
		)
		p.wireId = wire :: number
		wireToPacket[wire :: number] = p
	end
	rebuildCodec(remotesFolder:GetAttribute(SEED_ATTR) :: number)
end

local function ensureReady()
	if ready then
		return
	end
	if IS_SERVER then
		buildServerProtocol()
		ready = true
		return
	end
	if building then
		table.insert(waiters, coroutine.running())
		coroutine.yield()
		return
	end
	building = true
	buildClientProtocol()
	ready = true
	building = false
	for _, t in waiters do
		task.spawn(t)
	end
	table.clear(waiters)
end

local function getClientWriter(reliable: boolean): BitBuffer.Writer
	return if reliable then clientOut.reliable else clientOut.unreliable
end

local function getServerWriter(player: Player, reliable: boolean): BitBuffer.Writer
	local bucket = serverOut[player]
	if not bucket then
		bucket = newChannel()
		serverOut[player] = bucket
	end
	return if reliable then bucket.reliable else bucket.unreliable
end

local function logMessage(packet: Packet, dir: string, kind: string, value: any, src: buffer, from: number, to: number, player: Player?)
	if not Profiler.logging then
		return
	end
	local size = to - from
	local raw = buffer.create(size)
	buffer.copy(raw, 0, src, from, size)
	Profiler.logEvent({
		time = os.clock(),
		name = packet.name,
		dir = dir,
		kind = kind,
		bytes = size,
		value = value,
		raw = raw,
		player = if player then player.Name else nil,
	})
end

local inboundHooks: { Hook } = {}
local outboundHooks: { Hook } = {}

local function removeFrom(list: { Hook }, fn: Hook)
	local i = table.find(list, fn)
	if i then
		table.remove(list, i)
	end
end

function Kernel.addInboundHook(packet: Packet?, fn: Hook): () -> ()
	if packet then
		local list = packet.inboundHooks or {}
		packet.inboundHooks = list
		table.insert(list, fn)
		return function()
			if packet.inboundHooks then
				removeFrom(packet.inboundHooks, fn)
			end
		end
	end
	table.insert(inboundHooks, fn)
	return function()
		removeFrom(inboundHooks, fn)
	end
end

function Kernel.addOutboundHook(packet: Packet?, fn: Hook): () -> ()
	if packet then
		local list = packet.outboundHooks or {}
		packet.outboundHooks = list
		table.insert(list, fn)
		return function()
			if packet.outboundHooks then
				removeFrom(packet.outboundHooks, fn)
			end
		end
	end
	table.insert(outboundHooks, fn)
	return function()
		removeFrom(outboundHooks, fn)
	end
end

local function runChain(globalList: { Hook }, packetList: { Hook }?, info: HookInfo): boolean
	for _, h in globalList do
		if h(info) == false then
			return false
		end
	end
	if packetList then
		for _, h in packetList do
			if h(info) == false then
				return false
			end
		end
	end
	return true
end

local function runInbound(packet: Packet, kind: string, value: any, player: Player?): (boolean, any)
	if #inboundHooks == 0 and packet.inboundHooks == nil then
		return true, value
	end
	local info: HookInfo = { name = packet.name, kind = kind, dir = "in", player = player, value = value }
	if not runChain(inboundHooks, packet.inboundHooks, info) then
		return false, nil
	end
	return true, info.value
end

local function runOutbound(packet: Packet, kind: string, value: any, player: Player?): (boolean, any)
	if #outboundHooks == 0 and packet.outboundHooks == nil then
		return true, value
	end
	local info: HookInfo = { name = packet.name, kind = kind, dir = "out", player = player, value = value }
	if not runChain(outboundHooks, packet.outboundHooks, info) then
		return false, nil
	end
	return true, info.value
end

local function channelReliable(packet: Packet, reliable: boolean?): boolean
	if reliable == nil then
		return not packet.unreliable
	end
	return reliable
end

function Kernel.fireServer(packet: Packet, value: any, reliable: boolean?)
	ensureReady()
	assert(packet.direction ~= "s2c", `BiPolar: packet "{packet.name}" cannot be sent to the server (direction is s2c)`)
	local allowed, outValue = runOutbound(packet, "event", value, nil)
	if not allowed then
		return
	end
	local ser = packet.type :: Types.BipolarType
	local w = getClientWriter(channelReliable(packet, reliable))
	local before = w.cursor
	writeWireId(w, packet.wireId :: number)
	ser.write(w, outValue)
	Profiler.record(packet.name, "out", w.cursor - before, 1)
	logMessage(packet, "out", "event", outValue, w.buf, before, w.cursor, nil)
end

function Kernel.fireClient(packet: Packet, player: Player, value: any, reliable: boolean?)
	ensureReady()
	assert(packet.direction ~= "c2s", `BiPolar: packet "{packet.name}" cannot be sent to a client (direction is c2s)`)
	local allowed, outValue = runOutbound(packet, "event", value, player)
	if not allowed then
		return
	end
	local ser = packet.type :: Types.BipolarType
	local w = getServerWriter(player, channelReliable(packet, reliable))
	local before = w.cursor
	writeWireId(w, packet.wireId :: number)
	ser.write(w, outValue)
	Profiler.record(packet.name, "out", w.cursor - before, 1)
	logMessage(packet, "out", "event", outValue, w.buf, before, w.cursor, player)
end

local function fireMany(packet: Packet, value: any, except: Player?, reliable: boolean?)
	ensureReady()
	assert(packet.direction ~= "c2s", `BiPolar: packet "{packet.name}" cannot be sent to a client (direction is c2s)`)

	local players = Players:GetPlayers()
	local recipients = 0
	for _, player in players do
		if player ~= except then
			recipients += 1
		end
	end
	if recipients == 0 then
		return
	end

	local allowed, outValue = runOutbound(packet, "event", value, nil)
	if not allowed then
		return
	end
	local ser = packet.type :: Types.BipolarType
	local rel = channelReliable(packet, reliable)
	local payload = BitBuffer.Writer.new(64)
	ser.write(payload, outValue)
	local payloadSize = payload.cursor
	local payloadBuf = payload.buf
	local wireId = packet.wireId :: number

	for _, player in players do
		if player ~= except then
			local w = getServerWriter(player, rel)
			writeWireId(w, wireId)
			w:raw(payloadBuf, payloadSize)
		end
	end

	Profiler.record(packet.name, "out", (payloadSize + idBytes) * recipients, recipients)
	if Profiler.logging then
		local rw = BitBuffer.Writer.new(payloadSize + idBytes)
		writeWireId(rw, wireId)
		rw:raw(payloadBuf, payloadSize)
		Profiler.logEvent({
			time = os.clock(),
			name = packet.name,
			dir = "out",
			kind = "event",
			bytes = payloadSize + idBytes,
			value = outValue,
			raw = rw:result(),
			player = `(broadcast x{recipients})`,
		})
	end
end

function Kernel.fireAllClients(packet: Packet, value: any, reliable: boolean?)
	fireMany(packet, value, nil, reliable)
end

function Kernel.fireAllClientsExcept(packet: Packet, except: Player, value: any, reliable: boolean?)
	fireMany(packet, value, except, reliable)
end

local function invoke(packet: Packet, writer: BitBuffer.Writer, requestValue: any, player: Player?): any
	local id = nextRequestId
	nextRequestId += 1

	local ser = packet.requestType :: Types.BipolarType
	local before = writer.cursor
	writeWireId(writer, packet.wireId :: number)
	writer:u8(TAG_REQUEST)
	writer:varint(id)
	ser.write(writer, requestValue)
	Profiler.record(packet.name, "out", writer.cursor - before, 1)
	logMessage(packet, "out", "request", requestValue, writer.buf, before, writer.cursor, player)

	pending[id] = coroutine.running()
	task.delay(REQUEST_TIMEOUT, function()
		local co = pending[id]
		if co then
			pending[id] = nil
			task.spawn(co, nil, true)
		end
	end)

	local response, timedOut = coroutine.yield()
	if timedOut then
		error(`BiPolar: request "{packet.name}" timed out after {REQUEST_TIMEOUT}s`, 0)
	end
	return response
end

function Kernel.invokeServer(packet: Packet, requestValue: any): any
	ensureReady()
	assert(packet.direction ~= "s2c", `BiPolar: function "{packet.name}" cannot be invoked on the server (direction is s2c)`)
	return invoke(packet, getClientWriter(true), requestValue, nil)
end

function Kernel.invokeClient(packet: Packet, player: Player, requestValue: any): any
	ensureReady()
	assert(packet.direction ~= "c2s", `BiPolar: function "{packet.name}" cannot be invoked on a client (direction is c2s)`)
	return invoke(packet, getServerWriter(player, true), requestValue, player)
end

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

function Kernel.invokeClientExpect(packet: Packet, player: Player, requestValue: any, expected: any, kickReason: string?): boolean
	local ok, response = pcall(Kernel.invokeClient, packet, player, requestValue)
	if not ok or not deepEqual(response, expected) then
		player:Kick(kickReason or "Invalid network response")
		return false
	end
	return true
end

local function sendResponse(packet: Packet, id: number, value: any, player: Player?)
	local ser = packet.responseType :: Types.BipolarType
	local w = if IS_SERVER then getServerWriter(player :: Player, true) else getClientWriter(true)
	local before = w.cursor
	writeWireId(w, packet.wireId :: number)
	w:u8(TAG_RESPONSE)
	w:varint(id)
	ser.write(w, value)
	Profiler.record(packet.name, "out", w.cursor - before, 1)
	logMessage(packet, "out", "response", value, w.buf, before, w.cursor, player)
end

local function rejectInbound(packet: Packet, player: Player?, isRequest: boolean): boolean
	local wrongWay
	if IS_SERVER then
		wrongWay = packet.direction == "s2c"
	else
		wrongWay = packet.direction == "c2s"
	end
	if wrongWay and isRequest then
		local who = player and player.Name or "?"
		warn(`BiPolar: rejected inbound "{packet.name}" from {who} (wrong direction)`)
		return true
	end
	return false
end

local function dispatch(reader: BitBuffer.Reader, player: Player?)
	while not reader:eof() do
		local start = reader.cursor
		local wire = readWireId(reader)
		local packet = wireToPacket[wire]
		if not packet then
			warn(`BiPolar: received unknown packet id {wire}`)
			return
		end

		if packet.kind == "function" then
			local tag = reader:u8()
			local id = reader:varint()
			if tag == TAG_REQUEST then
				if rejectInbound(packet, player, true) then
					return
				end
				local okRead, req = pcall((packet.requestType :: Types.BipolarType).read, reader)
				if not okRead then
					warn(`BiPolar: failed to decode request "{packet.name}": {req}`)
					return
				end
				Profiler.record(packet.name, "in", reader.cursor - start, 1)
				logMessage(packet, "in", "request", req, reader.buf, start, reader.cursor, player)

				if not allowPacket(packet, player) then
					continue
				end

				local allowedReq, inReq = runInbound(packet, "request", req, player)
				if not allowedReq then
					continue
				end
				local handler = packet.invokeHandler
				if handler then
					task.spawn(function()
						local ok, resp
						if IS_SERVER then
							ok, resp = pcall(handler, player, inReq)
						else
							ok, resp = pcall(handler, inReq)
						end
						if ok then
							sendResponse(packet, id, resp, player)
						else
							warn(`BiPolar: invoke handler for "{packet.name}" errored: {resp}`)
						end
					end)
				else
					warn(`BiPolar: no invoke handler registered for "{packet.name}"`)
				end
			else
				local okRead, resp = pcall((packet.responseType :: Types.BipolarType).read, reader)
				if not okRead then
					warn(`BiPolar: failed to decode response "{packet.name}": {resp}`)
					return
				end
				Profiler.record(packet.name, "in", reader.cursor - start, 1)
				logMessage(packet, "in", "response", resp, reader.buf, start, reader.cursor, player)
				local co = pending[id]
				if co then
					pending[id] = nil
					task.spawn(co, resp)
				end
			end
		else
			if rejectInbound(packet, player, true) then
				return
			end
			local ok, value = pcall((packet.type :: Types.BipolarType).read, reader)
			if not ok then
				warn(`BiPolar: failed to decode packet "{packet.name}": {value}`)
				return
			end
			Profiler.record(packet.name, "in", reader.cursor - start, 1)
			logMessage(packet, "in", "event", value, reader.buf, start, reader.cursor, player)

			if not allowPacket(packet, player) then
				continue
			end

			local allowed, inValue = runInbound(packet, "event", value, player)
			if not allowed then
				continue
			end

			for _, handler in packet.handlers do
				local ok, err
				if IS_SERVER then
					ok, err = pcall(handler, player, inValue)
				else
					ok, err = pcall(handler, inValue)
				end
				if not ok then
					warn(`BiPolar: listener for "{packet.name}" errored: {err}`)
				end
			end
		end
	end
end

local function emit(buf: buffer): buffer
	scramble(buf)
	return buf
end

local function flushClient()
	local rw = clientOut.reliable
	if rw.cursor > 0 then
		reliableRemote:FireServer(emit(rw:result()))
		rw:reset()
	end
	local uw = clientOut.unreliable
	if uw.cursor > 0 then
		unreliableRemote:FireServer(emit(uw:result()))
		uw:reset()
	end
end

local function flushServer()
	for player, bucket in serverOut do
		local rw = bucket.reliable
		if rw.cursor > 0 then
			reliableRemote:FireClient(player, emit(rw:result()))
			rw:reset()
		end
		local uw = bucket.unreliable
		if uw.cursor > 0 then
			unreliableRemote:FireClient(player, emit(uw:result()))
			uw:reset()
		end
	end
end

local function waitForRemoteByClass(folder: Instance, className: string): Instance
	local found = folder:FindFirstChildWhichIsA(className)
	while not found do
		folder.ChildAdded:Wait()
		found = folder:FindFirstChildWhichIsA(className)
	end
	return found
end

local function setupRemotes()
	if IS_SERVER then
		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME

		reliableRemote = Instance.new("RemoteEvent")
		reliableRemote.Name = HttpService:GenerateGUID(false)
		reliableRemote.Parent = folder

		unreliableRemote = Instance.new("UnreliableRemoteEvent")
		unreliableRemote.Name = HttpService:GenerateGUID(false)
		unreliableRemote.Parent = folder

		remotesFolder = folder
		folder.Parent = ReplicatedStorage
	else
		local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
		remotesFolder = folder
		reliableRemote = waitForRemoteByClass(folder, "RemoteEvent") :: RemoteEvent
		unreliableRemote = waitForRemoteByClass(folder, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
	end
end

local function allowInbound(player: Player, size: number): boolean
	if size > security.maxBufferBytes then
		warn(`BiPolar: dropped oversized buffer ({size}B) from {player.Name}`)
		return false
	end
	local now = os.clock() // 1
	local info = rateByPlayer[player]
	if not info then
		info = {
			second = now, packets = 0, bytes = 0, strikes = 0,
			peakPackets = 0, peakBytes = 0, joinSecond = now, over = false,
		}
		rateByPlayer[player] = info
	elseif info.second ~= now then

		info.peakPackets = math.max(info.peakPackets, info.packets)
		info.peakBytes = math.max(info.peakBytes, info.bytes)
		info.strikes = if info.over then info.strikes + 1 else math.max(0, info.strikes - 1)
		info.second = now
		info.packets = 0
		info.bytes = 0
		info.over = false
	end
	info.packets += 1
	info.bytes += size

	local limitPackets, limitBytes
	if security.auto then
		if now - info.joinSecond < security.warmupSeconds then

			limitPackets = security.hardPacketsPerSecond
			limitBytes = security.hardBytesPerSecond
		else

			limitPackets = math.min(security.hardPacketsPerSecond, math.max(security.floorPacketsPerSecond, info.peakPackets * security.factor))
			limitBytes = math.min(security.hardBytesPerSecond, math.max(security.floorBytesPerSecond, info.peakBytes * security.factor))
		end
	else
		limitPackets = security.maxPacketsPerSecond
		limitBytes = security.maxBytesPerSecond
	end

	if info.packets > limitPackets or info.bytes > limitBytes then
		if not info.over then
			info.over = true

			if security.kick and info.strikes + 1 >= security.maxStrikes then
				player:Kick("Network flood protection")
			end
		end
		return false
	end
	return true
end

local function onServerReceive(player: Player, b: any)
	if typeof(b) ~= "buffer" then
		return
	end
	if not allowInbound(player, buffer.len(b)) then
		return
	end
	ensureReady()
	scramble(b)
	dispatch(BitBuffer.Reader.new(b), player)
end

local function onClientReceive(b: any)
	if typeof(b) ~= "buffer" then
		return
	end
	ensureReady()
	scramble(b)
	dispatch(BitBuffer.Reader.new(b), nil)
end

local function init()
	setupRemotes()
	if IS_SERVER then
		reliableRemote.OnServerEvent:Connect(onServerReceive)
		unreliableRemote.OnServerEvent:Connect(onServerReceive)
		Players.PlayerRemoving:Connect(function(player: Player)
			serverOut[player] = nil
			rateByPlayer[player] = nil
			packetRateByPlayer[player] = nil
		end)
		RunService.Heartbeat:Connect(flushServer)

		task.defer(ensureReady)
	else
		reliableRemote.OnClientEvent:Connect(onClientReceive)
		unreliableRemote.OnClientEvent:Connect(onClientReceive)
		RunService.Heartbeat:Connect(flushClient)
	end
end

init()

return Kernel
