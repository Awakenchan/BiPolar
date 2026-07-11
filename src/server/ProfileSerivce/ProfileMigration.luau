-- ProfileMigration — one-time port of legacy ProfileStore (CardGameData_v2) saves into the new
-- Suphi DataStore profile.
--
-- ProfileStore wraps your payload inside its own structure in the DataStore, so the old data can only
-- be read back THROUGH ProfileStore (a raw DataStore:GetAsync would return ProfileStore's wrapper, not
-- .Data). We read it view-only (no session lock, no write to the old store) and copy every field in.
--
-- Usage (in DataManager):
--   local ProfileMigration = require(script.Parent.ProfileMigration)
--   local migrateLegacyProfile = ProfileMigration.create("CardGameData_v2", PROFILE_TEMPLATE)
--   ... after a Suphi session opens successfully ...
--   migrateLegacyProfile(player, session)   -- session is the raw Suphi session (profile:RawSession())
--
-- The new template MUST contain `MigratedFromProfileStore = false` so Suphi's reconcile keeps the flag
-- and we never re-read the old store after the first successful migration.

local ProfileStore = require(game.ServerScriptService.ProfileStore)

local ProfileMigration = {}

local function deepCopyValue(v: any): any
	if type(v) == "table" then
		local t = {}
		for k, val in pairs(v) do
			t[k] = deepCopyValue(val)
		end
		return t
	end
	return v
end

local function looksUntouched(v): boolean
	if (tonumber(v.TotalRolls) or 0) > 0 then
		return false
	end
	if (tonumber(v.PlaytimeSeconds) or 0) > 0 then
		return false
	end
	if type(v.StackedInventory) == "table" and next(v.StackedInventory) ~= nil then
		return false
	end
	return true
end

-- Returns a migrate(player, session) function bound to one legacy store. The legacy ProfileStore handle
-- is created once and reused for every player.
function ProfileMigration.create(legacyStoreName: string, template: { [string]: any })
	local legacyStore = ProfileStore.New(legacyStoreName, template)

	return function(player: Player, session)
		local v = session.Value
		if v.MigratedFromProfileStore == true then
			return false
		end

		if not looksUntouched(v) then
			v.MigratedFromProfileStore = true
			return false
		end

		local viewProfile
		local ok = pcall(function()
			-- loleris ProfileStore read-only accessor. Older forks named this :ViewProfileAsync —
			-- swap the call if your ProfileStore build differs.
			viewProfile = legacyStore:GetAsync(tostring(player.UserId))
		end)

		if not ok then
			return false
		end

		local copied = false
		if viewProfile and type(viewProfile.Data) == "table" then
			for key, value in pairs(viewProfile.Data) do
				v[key] = deepCopyValue(value)
			end
			copied = true
		end

		-- Mark migrated whether or not a legacy save existed, so we never re-check this player.
		v.MigratedFromProfileStore = true
		return copied
	end
end

return ProfileMigration
