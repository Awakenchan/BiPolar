-- Converts a Roblox model (.rbxmx) into a Rojo source tree.
-- Usage: lune run tools/extract_rbxmx.luau <model> <outDir> [rootIndex]
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")

local modelPath = process.args[1]
local outDir = process.args[2]
local rootIndex = tonumber(process.args[3] or "1")

local model = roblox.deserializeModel(fs.readFile(modelPath))
local root = model[rootIndex]

local function suffix(inst): string
	if inst.ClassName == "Script" then
		return ".server.luau"
	elseif inst.ClassName == "LocalScript" then
		return ".client.luau"
	end
	return ".luau"
end

local count = 0
local function write(inst, dir)
	local children = inst:GetChildren()
	if inst.ClassName == "Folder" then
		fs.writeDir(`{dir}/{inst.Name}`)
		for _, c in children do
			write(c, `{dir}/{inst.Name}`)
		end
	elseif inst:IsA("LuaSourceContainer") then
		count += 1
		local src = inst.Source
		if #children > 0 then
			local sub = `{dir}/{inst.Name}`
			fs.writeDir(sub)
			fs.writeFile(`{sub}/init{suffix(inst)}`, src)
			for _, c in children do
				write(c, sub)
			end
		else
			fs.writeFile(`{dir}/{inst.Name}{suffix(inst)}`, src)
		end
	end
end

fs.writeDir(outDir)
write(root, outDir)
print(`extracted {count} scripts from root #{rootIndex} ({root.Name}) to {outDir}`)
