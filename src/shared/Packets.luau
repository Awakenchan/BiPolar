--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Bipolar = require(ReplicatedStorage:WaitForChild('Shared'):WaitForChild("BiPolar"))

local t = Bipolar.types
local Direction = Bipolar.Direction

local Packets = {}

Packets.PlayerState = Bipolar.define("PlayerState", {
	position = t.vector3half,
	health = t.u8,
	stamina = t.u8,
	lookAngle = t.f16,
	sprinting = t.boolean,
	crouching = t.boolean,
	jumping = t.boolean,
	aiming = t.boolean,
	fromUserId = t.optional(t.uint),
}, { unreliable = true, direction = Direction.Both, rateLimit = 90 })

Packets.Chat = Bipolar.define("Chat", {
	message = t.string,
}, { direction = Direction.Both, rateLimit = 5 })

Packets.Announcement = Bipolar.define("Announcement", {
	message = t.string,
	color = t.color3,
}, { direction = Direction.ServerToClient })

Packets.RequestRespawn = Bipolar.define("RequestRespawn", t.boolean, {
	direction = Direction.ClientToServer,
	rateLimit = 2,
})

Packets.Replicate = Bipolar.defineFunction("Replicate", t.u8, {
	serverTime = t.f64,
	playerCount = t.u8,
}, { direction = Direction.ClientToServer, rateLimit = 10 })

return Packets
