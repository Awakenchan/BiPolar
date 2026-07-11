--!strict
-- DataSession — adapter that wraps a Suphi DataStore session so it presents the small slice of the
-- old ProfileStore session API that DataManager already calls:
--   .Data            -> session.Value  (live table; reads + the single schema-wipe reassignment route here)
--   :Save()          -> session:Save()
--   :EndSession()    -> session:Destroy()  (Suphi saves, then closes)
--   :AddUserId(id)   -> appends to session.UserIds (GDPR)
--   :Reconcile()     -> no-op (Suphi :Open already reconciled Value against the template)
--   .OnSessionEnd    -> fires when Suphi closes the session unexpectedly (key stolen by another server)
local DataSession = {}

local function newSignal()
	local bindable = Instance.new("BindableEvent")
	return {
		Connect = function(_, fn: (...any) -> ())
			return bindable.Event:Connect(fn)
		end,
		Fire = function(_, ...)
			bindable:Fire(...)
		end,
		Destroy = function()
			bindable:Destroy()
		end,
	}
end

-- `.Data` is a virtual proxy onto session.Value: reads return the live table, and the one place that
-- REASSIGNS profile.Data (the schema wipe in DataManager) routes the new table back into session.Value
-- so Suphi persists it. Everything else (mutating profile.Data.X) hits the real table directly.
DataSession.__index = function(self, k)
	if k == "Data" then
		return rawget(self, "_session").Value
	end
	return rawget(DataSession, k)
end

DataSession.__newindex = function(self, k, v)
	if k == "Data" then
		rawget(self, "_session").Value = v
	else
		rawset(self, k, v)
	end
end

function DataSession.new(session)
	local self = setmetatable({
		_session = session,
		_ending = false,
		OnSessionEnd = newSignal(),
	}, DataSession)

	self._stateConn = session.StateChanged:Connect(function(state)
		if state == false and not rawget(self, "_ending") then
			rawget(self, "OnSessionEnd"):Fire()
		end
	end)

	return self
end

function DataSession:AddUserId(userId: number)
	local session = rawget(self, "_session")
	local ids = session.UserIds
	if type(ids) ~= "table" then
		ids = {}
		session.UserIds = ids
	end
	for _, id in ipairs(ids) do
		if id == userId then
			return
		end
	end
	table.insert(ids, userId)
end

function DataSession:Reconcile() end

function DataSession:Save()
	local session = rawget(self, "_session")
	if session.State == true then
		return session:Save()
	end
	return nil
end

function DataSession:EndSession()
	rawset(self, "_ending", true)
	local conn = rawget(self, "_stateConn")
	if conn then
		conn:Disconnect()
		rawset(self, "_stateConn", nil)
	end
	local session = rawget(self, "_session")
	if session.State ~= nil then
		session:Destroy()
	end
	local sig = rawget(self, "OnSessionEnd")
	if sig then
		sig:Destroy()
	end
end
function DataSession:RawSession()
	return rawget(self, "_session")
end

return DataSession
