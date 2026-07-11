--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local BiPolar = require(ReplicatedStorage:WaitForChild('Shared'):WaitForChild("BiPolar"))
local Packets = require(ReplicatedStorage:WaitForChild("Shared"))

BiPolar.setSecurity({ kick = false })

BiPolar:On(Packets.Chat, function(player: Player, data)
	print(`[server] {player.Name}: {data.message}`)
	BiPolar:Fire("Reliable", Packets.Chat, "All", { message = `[{player.Name}] {data.message}` })
end)

BiPolar.addInboundHook(Packets.Chat, function(info)
	if type(info.value) == "table" and info.value.message == "" then
		return false
	end
	return nil
end)

BiPolar:On(Packets.PlayerState, function(player: Player, data)
	local stop = BiPolar.debug.scope("RelayPlayerState")
	BiPolar:Fire("Unreliable", Packets.PlayerState, { except = player }, {
		position = data.position,
		health = data.health,
		stamina = data.stamina,
		lookAngle = data.lookAngle,
		sprinting = data.sprinting,
		crouching = data.crouching,
		jumping = data.jumping,
		aiming = data.aiming,
		fromUserId = player.UserId,
	})
	stop()
end)

BiPolar:On(Packets.RequestRespawn, function(player: Player, _data)
	task.spawn(function()
		if player.Character then
			player:LoadCharacter()
		end
	end)
end)

local function snapshot(_player: Player): { serverTime: number, playerCount: number }
	return {
		serverTime = os.clock(),
		playerCount = #Players:GetPlayers(),
	}
end
BiPolar:OnInvoke(Packets.Replicate, function(player: Player, _request)
	return snapshot(player)
end)

task.spawn(function()
	while true do
		task.wait(20)
		BiPolar:Fire("Reliable", Packets.Announcement, "All", {
			message = "BiPolar online.",
			color = Color3.fromRGB(120, 200, 255),
		})
	end
end)

print("[server] BiPolar demo ready")
