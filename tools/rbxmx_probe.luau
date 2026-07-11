local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local model = roblox.deserializeModel(fs.readFile("C:/Users/forg1/OneDrive/Documents/AuthServerV2.rbxmx"))

local function walk(inst, depth)
	local pad = string.rep("  ", depth)
	local extra = ""
	if inst:IsA("LuaSourceContainer") then
		local ok, src = pcall(function() return inst.Source end)
		if ok then extra = string.format("  [%d chars]", #src) end
	end
	print(string.format("%s%s (%s)%s", pad, inst.Name, inst.ClassName, extra))
	for _, child in inst:GetChildren() do
		walk(child, depth + 1)
	end
end

print("roots:", #model)
for _, root in model do
	walk(root, 0)
end
