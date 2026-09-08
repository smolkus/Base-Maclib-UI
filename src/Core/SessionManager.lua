return function(Import)
	local Build = Import("Build")
	local Janitor = Import("Janitor")
	local Players = game:GetService("Players")
	local TeleportService = game:GetService("TeleportService")
	local CoreGui = game:GetService("CoreGui")
	local LocalPlayer = Players.LocalPlayer
	local Environment = (getgenv and getgenv()) or _G
	local SessionManager = {}
	SessionManager.__index = SessionManager

	function SessionManager.new(runtime, config)
		local self = setmetatable({
			Runtime = runtime,
			Config = config,
			ReconnectJanitor = Janitor.new(),
			Janitor = Janitor.new(),
			ReconnectEnabled = false,
			TeleportQueued = false,
		}, SessionManager)
		self.Janitor:AddConnection(LocalPlayer.OnTeleport:Connect(function(state)
			if state == Enum.TeleportState.Started or state == Enum.TeleportState.InProgress then
				local ok, err = config:Flush(true)
				if not ok then runtime:Notify("Config flush failed", tostring(err)) end
			end
		end))
		return self
	end

	function SessionManager:_QueueFunction()
		return rawget(Environment, "queue_on_teleport")
			or (rawget(Environment, "syn") and rawget(Environment, "syn").queue_on_teleport)
			or rawget(Environment, "queueonteleport")
	end

	function SessionManager:SetAutoExecute(enabled)
		enabled = enabled == true
		self.Config.Account.Session.AutoExecute = enabled
		self.Config:SaveAccount()
		if not enabled or self.TeleportQueued then return enabled end

		local queue = self:_QueueFunction()
		if type(queue) ~= "function" then
			self.Runtime:Notify("Auto Execute unavailable", "This executor has no queue-on-teleport function.")
			return false
		end

		local payload = string.format([[
task.wait(1)
local env = (getgenv and getgenv()) or _G
if env.__BASE_HUB_TELEPORT_BOOT then return end
env.__BASE_HUB_TELEPORT_BOOT = true
local HttpService = game:GetService("HttpService")
local accountPath = %q
local loaderUrl = %q
local shouldRun = false
if isfile and readfile and isfile(accountPath) then
    local ok, state = pcall(HttpService.JSONDecode, HttpService, readfile(accountPath))
    shouldRun = ok and type(state) == "table" and type(state.Session) == "table" and state.Session.AutoExecute == true
end
if shouldRun then
    local ok, source = pcall(function()
        return game:HttpGet(loaderUrl .. "?t=" .. tostring(os.time()))
    end)
    if ok then
        local chunk, compileError = loadstring(source, "@Base-Hub/loader.lua")
        if chunk then chunk() else warn(compileError) end
    end
end
]], self.Config.AccountPath, Build.LoaderUrl)

		local ok, err = pcall(queue, payload)
		if not ok then
			self.Runtime:Notify("Auto Execute failed", tostring(err))
			return false
		end
		self.TeleportQueued = true
		return true
	end

	function SessionManager:SetAutoReconnect(enabled)
		enabled = enabled == true
		if self.ReconnectEnabled == enabled then return end
		self.ReconnectEnabled = enabled
		self.ReconnectJanitor:Cleanup()
		self.ReconnectJanitor = Janitor.new()
		if not enabled then return end

		local retrying = false
		local function reconnect()
			if retrying or not self.ReconnectEnabled or not self.Runtime.Alive then return end
			retrying = true
			local worker = task.spawn(function()
				local delaySeconds = 1
				for _ = 1, 5 do
					if not self.ReconnectEnabled or not self.Runtime.Alive then break end
					task.wait(delaySeconds)
					local flushOk, flushError = self.Config:Flush(true)
					if not flushOk then self.Runtime:Notify("Reconnect save failed", tostring(flushError)) end
					local ok = pcall(TeleportService.Teleport, TeleportService, game.PlaceId, LocalPlayer)
					if ok then break end
					delaySeconds = math.min(delaySeconds * 2, 12)
				end
				retrying = false
			end)
			if worker then self.ReconnectJanitor:Add(worker) end
		end

		local promptGui = CoreGui:FindFirstChild("RobloxPromptGui")
		local overlay = promptGui and promptGui:FindFirstChild("promptOverlay")
		if overlay then
			self.ReconnectJanitor:AddConnection(overlay.ChildAdded:Connect(function(child)
				if child.Name == "ErrorPrompt" or child:FindFirstChild("ErrorMessage") then reconnect() end
			end))
		end
		self.ReconnectJanitor:AddConnection(TeleportService.TeleportInitFailed:Connect(function(player)
			if player == LocalPlayer then reconnect() end
		end))
	end

	function SessionManager:Destroy()
		self.ReconnectEnabled = false
		self.ReconnectJanitor:Cleanup()
		self.Janitor:Cleanup()
	end

	return SessionManager
end
