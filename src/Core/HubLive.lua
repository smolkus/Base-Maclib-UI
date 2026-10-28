return function(Import)
	local Util = Import("Util")
	local HubReadouts = Import("HubReadouts")
	local HttpService = game:GetService("HttpService")
	local Players = game:GetService("Players")
	local HubLive = {}
	HubLive.__index = HubLive

	local BACKOFF = {1, 2, 5, 10, 30}
	local STATUS_EVERY = 10

	local function connector()
		local env = (getgenv and getgenv()) or _G
		local candidates = {
			rawget(env, "WebSocket"),
			rawget(env, "websocket"),
			type(rawget(env, "syn")) == "table" and rawget(env, "syn").websocket or nil,
		}
		for _, library in ipairs(candidates) do
			if type(library) == "table" and type(library.connect) == "function" then return library.connect end
			if type(library) == "table" and type(library.Connect) == "function" then return library.Connect end
		end
		return nil
	end

	local function plain(value, depth)
		depth = depth or 0
		if depth > 30 then return nil end
		local kind = typeof(value)
		if kind == "EnumItem" then return value.Name end
		if kind == "Color3" then return {R = value.R, G = value.G, B = value.B} end
		if kind == "number" or kind == "string" or kind == "boolean" then return value end
		if kind ~= "table" then return nil end
		local output = {}
		for key, child in pairs(value) do output[key] = plain(child, depth + 1) end
		return output
	end
	HubLive.Plain = plain

	local function same(left, right)
		local ok, equal = pcall(function()
			return HttpService:JSONEncode(plain(left)) == HttpService:JSONEncode(plain(right))
		end)
		return ok and equal
	end

	function HubLive.ApplyDesired(ctx, values, deviceOnly)
		local registry = ctx.Registry
		local skip = {}
		for _, flag in ipairs(type(deviceOnly) == "table" and deviceOnly or {}) do skip[tostring(flag)] = true end
		local adjusted, failed, changed = {}, 0, 0
		registry.RemoteDepth = (registry.RemoteDepth or 0) + 1
		for flag, value in pairs(type(values) == "table" and values or {}) do
			if registry.Entries[flag] and not skip[flag] and not same(registry.Values[flag], value) then
				local ok, applied = registry:SetFromRemote(flag, value)
				if not ok then
					failed = failed + 1
				else
					changed = changed + 1
					if not same(applied, value) then adjusted[flag] = plain(applied) end
				end
			end
		end
		registry.RemoteDepth = registry.RemoteDepth - 1
		if changed > 0 then ctx.Config:ScheduleAutoSave() end
		return failed == 0, adjusted, changed
	end

	function HubLive.new(ctx, key)
		return setmetatable({
			Ctx = ctx,
			Key = key,
			Socket = nil,
			Ready = false,
			Stopped = false,
			Attempt = 0,
			LastStatus = nil,
		}, HubLive)
	end

	function HubLive:_Send(message)
		if not self.Socket then return false end
		local ok = pcall(function() self.Socket:Send(HttpService:JSONEncode(message)) end)
		return ok
	end

	function HubLive:_User()
		return {id = tostring(Players.LocalPlayer.UserId), name = Players.LocalPlayer.Name}
	end

	function HubLive:Hello()
		if not self.Ready then return end
		local ctx = self.Ctx
		self.LastStatus = nil
		self:_Send({
			op = "hello",
			placeId = tostring(game.PlaceId),
			jobId = tostring(game.JobId),
			user = self:_User(),
			schema = ctx.Schema:Build(game.PlaceId),
			values = plain(ctx.Registry:Snapshot()),
		})
		self:Status()
	end

	function HubLive:Changed(flag, value)
		if (self.Ctx.Registry.RemoteDepth or 0) > 0 then return end
		if self.Ready then self:_Send({op = "changed", flag = flag, value = plain(value)}) end
	end

	function HubLive:Loaded(name)
		if not self.Ready then return end
		self:_Send({op = "loaded", name = tostring(name), values = plain(self.Ctx.Registry:Snapshot())})
	end

	function HubLive:Status()
		if not self.Ready then return end
		local readouts = HubReadouts.Collect(self.Ctx.Runtime)
		local encoded = HttpService:JSONEncode(readouts)
		if encoded == self.LastStatus then return end
		self.LastStatus = encoded
		self:_Send({op = "status", readouts = readouts})
	end

	function HubLive:_Ack(id, ok, value)
		self:_Send({op = "ack", id = id, ok = ok == true, value = value})
	end

	function HubLive:_Handle(message)
		local ctx = self.Ctx
		if message.op == "ready" then
			self.Ready = true
			self.Attempt = 0
			self:Hello()
			if not self.Announced then
				self.Announced = true
				ctx.Runtime:Notify("Hub", "Live on jexvral.xyz.")
			end
		elseif message.op == "error" then
			ctx.Runtime:Notify("Hub", "Live control refused: " .. tostring(message.reason))
			self.Refused = true
		elseif message.op == "ping" then
			self:_Send({op = "pong"})
		elseif message.op == "apply" then
			local ok, adjusted, changed = HubLive.ApplyDesired(ctx, message.values, message.deviceOnly)
			self:_Ack(message.id, ok, adjusted)
			if changed > 0 then
				ctx.Runtime.HubRole = {Name = message.role, Version = message.version}
			end
		elseif message.op == "run" then
			local ok = ctx.Registry:RunAction(tostring(message.action))
			self:_Ack(message.id, ok)
		end
	end

	function HubLive:_Connect()
		local connect = connector()
		if not connect then
			self.Ctx.Runtime:Notify("Hub", "This executor has no WebSocket; live control is off.")
			return false
		end
		local url = string.gsub(self.Ctx.Build.ApiUrl, "^http", "ws") .. "/v1/hub/live"
		local ok, socket = pcall(connect, url)
		if not ok or not socket then return false end
		self.Socket = socket
		local closed = Instance.new("BindableEvent")
		socket.OnMessage:Connect(function(raw)
			local decoded
			if pcall(function() decoded = HttpService:JSONDecode(raw) end) and type(decoded) == "table" then
				Util.SafeCall("hub live message", self._Handle, self, decoded)
			end
		end)
		socket.OnClose:Connect(function() closed:Fire() end)
		self:_Send({op = "auth", key = self.Key})
		closed.Event:Wait()
		closed:Destroy()
		self.Socket = nil
		self.Ready = false
		return true
	end

	function HubLive:Start()
		task.spawn(function()
			while not self.Stopped and self.Ctx.Runtime.Alive do
				local connected = self:_Connect()
				if connected == false and not connector() then return end
				if self.Stopped or self.Refused or not self.Ctx.Runtime.Alive then return end
				self.Attempt = math.min(self.Attempt + 1, #BACKOFF)
				task.wait(BACKOFF[self.Attempt])
			end
		end)
		task.spawn(function()
			while not self.Stopped and self.Ctx.Runtime.Alive do
				task.wait(STATUS_EVERY)
				Util.SafeCall("hub status", self.Status, self)
			end
		end)
	end

	function HubLive:Stop()
		self.Stopped = true
		self.Ready = false
		if self.Socket then pcall(function() self.Socket:Close() end) end
	end

	return HubLive
end
