--!strict

local RunService = game:GetService("RunService")

export type Stat = {
	outBytes: number,
	outCount: number,
	inBytes: number,
	inCount: number,
}

export type Snapshot = {
	packets: { [string]: Stat },
	totalOutBytes: number,
	totalInBytes: number,
	totalOutCount: number,
	totalInCount: number,
}

export type LogEntry = {
	time: number,
	name: string,
	dir: string,
	kind: string,
	bytes: number,
	value: any,
	raw: buffer?,
	player: string?,
}

local Profiler = {}

Profiler.logging = false

local stats: { [string]: Stat } = {}
local lastStats: { [string]: Stat } = {}
local rates: { [string]: Stat } = {}
local listeners: { (rates: { [string]: Stat }) -> () } = {}

local log: { LogEntry } = {}
local logListeners: { (entry: LogEntry) -> () } = {}
local MAX_LOG = 250

local function zeroStat(): Stat
	return { outBytes = 0, outCount = 0, inBytes = 0, inCount = 0 }
end

local function getStat(name: string): Stat
	local s = stats[name]
	if not s then
		s = zeroStat()
		stats[name] = s
	end
	return s
end

function Profiler.record(name: string, dir: string, bytes: number, count: number)
	local s = getStat(name)
	if dir == "out" then
		s.outBytes += bytes
		s.outCount += count
	else
		s.inBytes += bytes
		s.inCount += count
	end
end

function Profiler.snapshot(): Snapshot
	local packets: { [string]: Stat } = {}
	local totalOutBytes, totalInBytes = 0, 0
	local totalOutCount, totalInCount = 0, 0
	for name, s in stats do
		packets[name] = { outBytes = s.outBytes, outCount = s.outCount, inBytes = s.inBytes, inCount = s.inCount }
		totalOutBytes += s.outBytes
		totalInBytes += s.inBytes
		totalOutCount += s.outCount
		totalInCount += s.inCount
	end
	return {
		packets = packets,
		totalOutBytes = totalOutBytes,
		totalInBytes = totalInBytes,
		totalOutCount = totalOutCount,
		totalInCount = totalInCount,
	}
end

function Profiler.rates(): { [string]: Stat }
	return rates
end

function Profiler.onInterval(cb: (rates: { [string]: Stat }) -> ()): () -> ()
	table.insert(listeners, cb)
	return function()
		local i = table.find(listeners, cb)
		if i then
			table.remove(listeners, i)
		end
	end
end

function Profiler.setLogging(enabled: boolean)
	Profiler.logging = enabled
end

function Profiler.logEvent(entry: LogEntry)
	table.insert(log, entry)
	if #log > MAX_LOG then
		table.remove(log, 1)
	end
	for _, cb in logListeners do
		task.spawn(cb, entry)
	end
end

function Profiler.getLog(): { LogEntry }
	return log
end

function Profiler.onLog(cb: (entry: LogEntry) -> ()): () -> ()
	table.insert(logListeners, cb)
	return function()
		local i = table.find(logListeners, cb)
		if i then
			table.remove(logListeners, i)
		end
	end
end

function Profiler.clearLog()
	table.clear(log)
end

local accumulated = 0
RunService.Heartbeat:Connect(function(dt: number)
	accumulated += dt
	if accumulated < 1 then
		return
	end
	accumulated = 0

	local newRates: { [string]: Stat } = {}
	for name, s in stats do
		local prev = lastStats[name] or zeroStat()
		newRates[name] = {
			outBytes = s.outBytes - prev.outBytes,
			outCount = s.outCount - prev.outCount,
			inBytes = s.inBytes - prev.inBytes,
			inCount = s.inCount - prev.inCount,
		}
		lastStats[name] = { outBytes = s.outBytes, outCount = s.outCount, inBytes = s.inBytes, inCount = s.inCount }
	end
	rates = newRates

	for _, cb in listeners do
		task.spawn(cb, newRates)
	end
end)

export type FrameSample = {
	total: number,
	totalOut: number,
	totalIn: number,
	perPacket: { [string]: number },
}

local MAX_FRAMES = 256
local frames: { FrameSample } = {}
local frameLast: { [string]: { out: number, inb: number } } = {}
local frameListeners: { () -> () } = {}
local paused = false

function Profiler.reset()
	table.clear(stats)
	table.clear(lastStats)
	table.clear(rates)
	table.clear(log)
	table.clear(frames)
	table.clear(frameLast)
end

function Profiler.setPaused(value: boolean)
	paused = value
end

function Profiler.isPaused(): boolean
	return paused
end

function Profiler.frames(): { FrameSample }
	return frames
end

function Profiler.maxFrames(): number
	return MAX_FRAMES
end

function Profiler.onFrame(cb: () -> ()): () -> ()
	table.insert(frameListeners, cb)
	return function()
		local i = table.find(frameListeners, cb)
		if i then
			table.remove(frameListeners, i)
		end
	end
end

RunService.Heartbeat:Connect(function()
	local sample: FrameSample = { total = 0, totalOut = 0, totalIn = 0, perPacket = {} }
	for name, s in stats do
		local prev = frameLast[name]
		local pOut = if prev then prev.out else 0
		local pIn = if prev then prev.inb else 0
		local dOut = s.outBytes - pOut
		local dIn = s.inBytes - pIn

		if dOut ~= 0 or dIn ~= 0 then
			if not prev then
				prev = { out = 0, inb = 0 }
				frameLast[name] = prev
			end
			prev.out = s.outBytes
			prev.inb = s.inBytes
		end
		if dOut > 0 or dIn > 0 then
			sample.perPacket[name] = dOut + dIn
			sample.totalOut += dOut
			sample.totalIn += dIn
		end
	end
	sample.total = sample.totalOut + sample.totalIn

	if paused then
		return
	end
	table.insert(frames, sample)
	if #frames > MAX_FRAMES then
		table.remove(frames, 1)
	end
	for _, cb in frameListeners do
		task.spawn(cb)
	end
end)

return Profiler
