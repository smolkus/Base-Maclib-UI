return function(Import)
	local Util = Import("Util")
	local HubLive = Import("HubLive")
	local HttpService = game:GetService("HttpService")
	local Players = game:GetService("Players")
	local CloudSync = {}

	local DEFAULT_CONFIG = "main"

	local function environment()
		return (getgenv and getgenv()) or _G
	end

	local function detectKey()
		local key = tostring(rawget(environment(), "key") or "")
		if string.match(key, "^jxk_[%w_%-]+$") then return key end
		return nil
	end

	local function executorRequest()
		local env = environment()
		if type(env.request) == "function" then return env.request end
		if type(env.http_request) == "function" then return env.http_request end
		if type(env.syn) == "table" and type(env.syn.request) == "function" then return env.syn.request end
		return nil
	end

	local function callApi(ctx, method, path, body)
		local cloud = ctx.Runtime.Cloud
		local ok, response = pcall(cloud.Request, {
			Url = ctx.Build.ApiUrl .. path,
			Method = method,
			Headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = "Bearer " .. cloud.Key,
			},
			Body = body and HttpService:JSONEncode(body) or nil,
		})
		if not ok then return false, "request failed" end
		local status = tonumber(type(response) == "table" and (response.StatusCode or response.Status)) or 0
		local decoded
		if type(response) == "table" and type(response.Body) == "string" and response.Body ~= "" then
			pcall(function() decoded = HttpService:JSONDecode(response.Body) end)
		end
		if status < 200 or status >= 300 then
			return false, (decoded and decoded.error) or ("HTTP " .. tostring(status))
		end
		return true, decoded
	end

	local function readAll(ctx)
		local configs = {}
		for _, name in ipairs(ctx.Config:List()) do
			local data = ctx.Config:_ReadConfig(name)
			if type(data) == "table" then configs[name] = data end
		end
		return configs
	end

	function CloudSync.ApplyConfig(ctx, name, data)
		if type(data) ~= "table" then return false end
		local clean = ctx.Config:SanitizeName(name)
		if clean == "" then return false end
		local ok = ctx.FileSystem:WriteJson(ctx.Config:_ConfigPath(clean), data)
		if not ok then return false end
		ctx.Config.KnownRevisions[string.lower(clean)] = data.Revision
		if string.lower(ctx.Config.Account.SelectedConfig) == string.lower(clean) then
			return ctx.Config:Load(clean) ~= false
		end
		return true
	end

	function CloudSync.Push(ctx, name)
		if not ctx.Runtime.CloudLinked then return false end
		local data = ctx.Config:_ReadConfig(name)
		if type(data) ~= "table" then return false end
		return callApi(ctx, "PUT", "/v1/hub/loader/configs/" .. HttpService:UrlEncode(name), {
			placeId = tostring(game.PlaceId),
			data = data,
			isDefault = string.lower(name) == DEFAULT_CONFIG,
		})
	end

	function CloudSync.Remove(ctx, name)
		if not ctx.Runtime.CloudLinked then return false end
		return callApi(ctx, "DELETE", "/v1/hub/loader/configs/" .. HttpService:UrlEncode(name)
			.. "?placeId=" .. tostring(game.PlaceId))
	end

	function CloudSync.Run(ctx)
		local ok, result = callApi(ctx, "POST", "/v1/hub/loader/hello", {
			placeId = tostring(game.PlaceId),
			jobId = tostring(game.JobId),
			user = {id = tostring(Players.LocalPlayer.UserId), name = Players.LocalPlayer.Name},
			selected = ctx.Config.Account.SelectedConfig,
			configs = readAll(ctx),
		})
		if not ok then
			ctx.Runtime:Notify("Hub", "Sync failed: " .. tostring(result))
			return
		end
		ctx.Runtime.CloudLinked = true
		local applied = 0
		for _, item in ipairs(type(result.pending) == "table" and result.pending or {}) do
			if CloudSync.ApplyConfig(ctx, tostring(item.name), item.data) then
				applied = applied + 1
				CloudSync.Push(ctx, tostring(item.name))
			end
		end
		ctx.Runtime:Notify("Hub", applied > 0
			and string.format("Synced. %d config(s) came from the website.", applied)
			or "Synced with the Jexvral Hub.")
		local live = HubLive.new(ctx, ctx.Runtime.Cloud.Key, CloudSync)
		ctx.Runtime.HubLive = live
		ctx.Runtime.Janitor:Add(function() live:Stop() end)
		live:Start()
	end

	function CloudSync.Start(ctx)
		local key = detectKey()
		if not key then return end
		local request = executorRequest()
		if not request then
			ctx.Runtime:Notify("Hub", "This executor has no HTTP request function; Hub sync is off.")
			return
		end
		ctx.Runtime.Cloud = {Key = key, Request = request}

		local config = ctx.Config
		local baseSave = config.Save
		function config:Save(name, ignoreRevision)
			local results = table.pack(baseSave(self, name, ignoreRevision))
			if results[1] then
				local saved = self:ResolveName(name or self.Account.SelectedConfig)
				task.spawn(function() Util.SafeCall("hub push", CloudSync.Push, ctx, saved) end)
			end
			return table.unpack(results, 1, results.n)
		end
		local baseDelete = config.Delete
		function config:Delete(name)
			local resolved = self:ResolveName(name)
			local results = table.pack(baseDelete(self, name))
			if results[1] and resolved then
				task.spawn(function() Util.SafeCall("hub remove", CloudSync.Remove, ctx, resolved) end)
			end
			return table.unpack(results, 1, results.n)
		end
		local baseLoad = config.Load
		function config:Load(name)
			local results = table.pack(baseLoad(self, name))
			local live = ctx.Runtime.HubLive
			if results[1] and live then
				task.spawn(function()
					live:_Send({op = "selected", name = self.Account.SelectedConfig})
					live:Hello()
				end)
			end
			return table.unpack(results, 1, results.n)
		end

		task.spawn(function() Util.SafeCall("hub sync", CloudSync.Run, ctx) end)
	end

	return CloudSync
end
