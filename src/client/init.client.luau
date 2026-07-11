--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BiPolar = require(ReplicatedStorage.Shared.BiPolar)
local Packets = require(ReplicatedStorage.Shared.Packets)

local localPlayer = Players.LocalPlayer

BiPolar:On(Packets.Chat, function(data)
	print(`[client] {data.message}`)
end)

BiPolar:On(Packets.Announcement, function(data)
	print(`[client] ANNOUNCEMENT: {data.message}`)
end)

BiPolar:On(Packets.PlayerState, function(_data) end)

local function anyKeyDown(keys: { Enum.KeyCode }): boolean
	for _, key in keys do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

local SEND_HZ = 20
local SEND_INTERVAL = 1 / SEND_HZ
local POS_EPSILON = 0.05

type State = {
	position: Vector3,
	health: number,
	stamina: number,
	lookAngle: number,
	sprinting: boolean,
	crouching: boolean,
	jumping: boolean,
	aiming: boolean,
}

local accumulator = 0
local lastSent: State? = nil

local function changed(a: State, b: State): boolean
	return (a.position - b.position).Magnitude > POS_EPSILON
		or a.health ~= b.health
		or a.stamina ~= b.stamina
		or math.abs(a.lookAngle - b.lookAngle) > 0.01
		or a.sprinting ~= b.sprinting
		or a.crouching ~= b.crouching
		or a.jumping ~= b.jumping
		or a.aiming ~= b.aiming
end

RunService.Heartbeat:Connect(function(dt: number)
	accumulator += dt
	if accumulator < SEND_INTERVAL then
		return
	end
	accumulator = 0

	local character = localPlayer.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid then
		return
	end
	local camera = workspace.CurrentCamera
	local state: State = {
		position = root.Position,
		health = math.clamp(math.floor((humanoid :: Humanoid).Health), 0, 255),
		stamina = 100,
		lookAngle = if camera then camera.CFrame.LookVector.Y else 0,
		sprinting = anyKeyDown({ Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift }),
		crouching = anyKeyDown({ Enum.KeyCode.C, Enum.KeyCode.LeftControl }),
		jumping = (humanoid :: Humanoid):GetState() == Enum.HumanoidStateType.Jumping,
		aiming = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2),
	}

	if lastSent == nil or changed(lastSent, state) then
		lastSent = state
		BiPolar:Fire("Unreliable", Packets.PlayerState, state)
	end
end)

task.spawn(function()
	while true do
		task.wait(5)
		BiPolar:Fire("Reliable", Packets.Chat, { message = `hi from {localPlayer.Name}` })
	end
end)

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if not processed and input.KeyCode == Enum.KeyCode.R then
		BiPolar:Fire("Reliable", Packets.RequestRespawn, true)
	end
end)

task.spawn(function()
	while true do
		task.wait(8)
		local snap = BiPolar:Invoke(Packets.Replicate, 0)
		print(`[client] snapshot: {snap.playerCount} players @ {snap.serverTime}`)
	end
end)

print("[client] BiPolar demo ready -- move around; F3 = profiler, R = respawn")
