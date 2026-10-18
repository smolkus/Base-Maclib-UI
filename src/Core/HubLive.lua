return function(Import)
	local Util = Import("Util")
	local HttpService = game:GetService("HttpService")
	local Players = game:GetService("Players")
	local HubLive = {}
	HubLive.__index = HubLive

	local BACKOFF = {1, 2, 5, 10, 30}

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

	function HubLive.new(ctx, key, cloud)
		return setmetatable({
			Ctx = ctx,
			Key = key,
			Cloud = cloud,
			Socket = nil,
			Ready = false,
			Stopped = false,
			Attempt = 0,
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
		self:_Send({
			op = "hello",
			placeId = tostring(game.PlaceId),
			jobId = tostring(game.JobId),
			user = self:_User(),
			selected = ctx.Config.Account.SelectedConfig,
			schema = ctx.Schema:Build(game.PlaceId),
			values = plain(ctx.Registry:Snapshot()),
		})
	end

	function HubLive:Changed(flag, value)
		if self.Ready then self:_Send({op = "changed", flag = flag, value = plain(value)}) end
	end

	function HubLive:_Ack(id, ok, value)
		self:_Send({op = "ack", id = id, ok = ok == true, value = plain(value)})
	end

	function HubLive:_Handle(message)
		local ctx = self.Ctx
		if message.op == "ready" then
			self.Ready = true
			self.Attempt = 0
			self:Hello()
			if not self.Announced then
				self.Announced = true
				ctx.Runtime:Notify("Hub", "Live control is on. Open the Hub on jexvral.xyz.")
			end
		elseif message.op == "error" then
			ctx.Runtime:Notify("Hub", "Live control refused: " .. tostring(message.reason))
			self.Refused = true
		elseif message.op == "ping" then
			self:_Send({op = "pong"})
		elseif message.op == "set" then
			local ok, applied = ctx.Registry:SetFromRemote(tostring(message.flag), message.value)
			self:_Ack(message.id, ok, ok and applied or nil)
		elseif message.op == "load" then
			local ok = ctx.Config:Load(tostring(message.name))
			self:_Ack(message.id, ok)
		elseif message.op == "apply" then
			local ok = self.Cloud.ApplyConfig(ctx, tostring(message.name), message.data)
			self:_Ack(message.id, ok)
			if ok then self:Hello() end
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
	end

	function HubLive:Stop()
		self.Stopped = true
		self.Ready = false
		if self.Socket then pcall(function() self.Socket:Close() end) end
	end

	return HubLive
end
