-- Compile-check every Luau source under src/ WITHOUT running it, to catch parse
-- errors that the other tools miss:
--   * selene tolerates some Luau syntax it shouldn't (e.g. `{{` inside a backtick
--     interpolated string is a real compile error but lints clean);
--   * the lune unit tests only load BitBuffer + Types, so a parse error in
--     init/Kernel/DebugUI or the demos goes unnoticed until it hits Studio;
--   * `rojo build` packages source as-is and never compiles it.
-- luau.load() parses + compiles the chunk (throwing on any syntax error) but we
-- never call the returned function, so modules that need `game`/Instances are
-- still safe to check here.
-- Run: lune run tools/syntax_check.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local function collect(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			collect(path, out)
		elseif string.match(entry, "%.luau?$") then
			table.insert(out, path)
		end
	end
end

local files: { string } = {}
collect("src", files)
table.sort(files)

local bad = 0
for _, f in files do
	local ok, err = pcall(function()
		luau.load(fs.readFile(f), { debugName = f })
	end)
	if not ok then
		bad += 1
		print("FAIL - " .. f .. "\n        " .. tostring(err))
	end
end

if bad == 0 then
	print(string.format("All %d Luau modules parse.", #files))
else
	error(string.format("%d of %d modules failed to parse.", bad, #files), 0)
end
