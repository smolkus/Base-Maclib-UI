return function(Import)
	local Util = Import("Util")
	local HubLive = Import("HubLive")
	local HttpService = game:GetService("HttpService")
	local Players = game:GetService("Players")
	local CloudSync = {}

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

	local function user()
		return {id = tostring(Players.LocalPlayer.UserId), name = Players.LocalPlayer.Name}
	end

	local function encode(value)
		local ok, text = pcall(function() return HttpService:JSONEncode(HubLive.Plain(value)) end)
		return ok and text or nil
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

	local function modulesOf(ctx, values)
		local registry = ctx.Registry
		local modules = {}
		for flag, value in pairs(values) do
			local entry = registry.Entries[flag]
			local owner = (entry and entry.Owner) or string.match(flag, "^([^.]+)") or "Core"
			modules[owner] = modules[owner] or {Version = registry.OwnerVersions[owner] or 1, Values = {}}
			modules[owner].Values[flag] = Util.Clone(value)
		end
		return modules
	end

	local function valuesOf(ctx, name)
		local data = ctx.Config:_ReadConfig(name)
		if type(data) ~= "table" then return nil end
		return ctx.Config:_FlattenModules(data.Modules), data
	end

	local function refreshList(ctx)
		local refresh = ctx.Runtime.RefreshConfigs
		if type(refresh) == "function" then Util.SafeCall("hub config list", refresh) end
	end

	-- Loads a config without telling the server (the server asked for it).
	local function quietLoad(ctx, name)
		local sync = ctx.Runtime.HubSync
		sync.Quiet = sync.Quiet + 1
		local ok, err = ctx.Config:Load(name)
		sync.Quiet = sync.Quiet - 1
		return ok, err
	end

	-- Writes a config the server sent. Values the server keeps off its tables (webhooks) stay as
	-- the device has them. Returns the local name.
	function CloudSync.WriteConfig(ctx, config)
		local manager = ctx.Config
		local sync = ctx.Runtime.HubSync
		local name = manager:ResolveName(config.name) or manager:SanitizeName(config.name)
		if name == "" then return nil end
		local values, data = valuesOf(ctx, name)
		values = values or {}
		data = data or manager:_NewConfig(name)
		local keep = {}
		for _, flag in ipairs(type(config.deviceOnly) == "table" and config.deviceOnly or {}) do keep[flag] = true end
		for flag, value in pairs(type(config.values) == "table" and config.values or {}) do
			if not keep[flag] then values[flag] = Util.Clone(value) end
		end
		data.Name = name
		data.Modules = modulesOf(ctx, values)
		data.HubVersion = tonumber(config.version)
		data.Revision = (tonumber(data.Revision) or 0) + 1
		if not ctx.FileSystem:WriteJson(manager:_ConfigPath(name), data) then return nil end
		manager.KnownRevisions[string.lower(name)] = data.Revision
		sync.Synced[string.lower(name)] = encode(values)
		return name
	end

	-- A config the server sent: write it, and load it when this account uses it.
	function CloudSync.Received(ctx, config)
		local name = CloudSync.WriteConfig(ctx, config)
		if not name then return end
		refreshList(ctx)
		if string.lower(ctx.Config.Account.SelectedConfig) == string.lower(name) then quietLoad(ctx, name) end
	end

	-- A config deleted on the website: delete it here; if it was in use, go back to main.
	function CloudSync.Removed(ctx, name)
		local manager = ctx.Config
		local resolved = manager:ResolveName(name)
		if not resolved or string.lower(resolved) == "main" then return end
		local wasSelected = string.lower(manager.Account.SelectedConfig) == string.lower(resolved)
		ctx.FileSystem:Delete(manager:_ConfigPath(resolved))
		manager.KnownRevisions[string.lower(resolved)] = nil
		ctx.Runtime.HubSync.Synced[string.lower(resolved)] = nil
		if wasSelected then
			manager.Account.SelectedConfig = manager:ResolveName("main") or manager:List()[1]
			quietLoad(ctx, manager.Account.SelectedConfig)
		end
		refreshList(ctx)
	end

	-- The website switched this account to another config.
	function CloudSync.Select(ctx, name)
		local resolved = ctx.Config:ResolveName(name)
		if not resolved then return false end
		local ok = quietLoad(ctx, resolved)
		refreshList(ctx)
		return ok ~= false
	end

	local function push(ctx, name)
		local values, data = valuesOf(ctx, name)
		if not values then return end
		local key = string.lower(name)
		local sync = ctx.Runtime.HubSync
		local text = encode(values)
		if text and sync.Synced[key] == text then return end
		local ok, result = callApi(ctx, "PUT", "/v1/hub/loader/configs/" .. HttpService:UrlEncode(name), {
			placeId = tostring(game.PlaceId),
			user = user(),
			values = HubLive.Plain(values),
		})
		if not ok then
			ctx.Runtime:Notify("Hub", "Could not sync " .. name .. ": " .. tostring(result))
			return
		end
		sync.Synced[key] = text
		data.HubVersion = tonumber(result.version)
		ctx.FileSystem:WriteJson(ctx.Config:_ConfigPath(name), data)
	end

	local function select(ctx, name)
		callApi(ctx, "POST", "/v1/hub/loader/select", {placeId = tostring(game.PlaceId), user = user(), name = name})
	end

	function CloudSync.Run(ctx)
		local manager = ctx.Config
		local configs = {}
		for _, name in ipairs(manager:List()) do
			local values, data = valuesOf(ctx, name)
			if values then configs[name] = {values = HubLive.Plain(values), version = tonumber(data.HubVersion)} end
		end
		local ok, result = callApi(ctx, "POST", "/v1/hub/loader/hello", {
			placeId = tostring(game.PlaceId),
			jobId = tostring(game.JobId),
			user = user(),
			selected = manager.Account.SelectedConfig,
			configs = configs,
		})
		if not ok then
			ctx.Runtime:Notify("Hub", "Sync failed: " .. tostring(result))
			return
		end
		ctx.Runtime.CloudLinked = true
		for _, config in ipairs(type(result.configs) == "table" and result.configs or {}) do
			CloudSync.WriteConfig(ctx, config)
		end
		for _, name in ipairs(type(result.removed) == "table" and result.removed or {}) do
			CloudSync.Removed(ctx, tostring(name))
		end
		local selected = manager:ResolveName(tostring(result.selected)) or manager:ResolveName("main")
		if selected then
			manager.Account.SelectedConfig = selected
			quietLoad(ctx, selected)
		end
		refreshList(ctx)
		ctx.Runtime:Notify("Hub", "Synced. Config " .. tostring(selected) .. ".")
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
			ctx.Runtime:Notify("Hub", "This executor has no HTTP request function; the Hub is off.")
			return
		end
		ctx.Runtime.Cloud = {Key = key, Request = request}
		ctx.Runtime.HubSync = {Quiet = 0, Synced = {}}
		ctx.Runtime.Readouts = ctx.Runtime.Readouts or {}

		local manager = ctx.Config
		local sync = ctx.Runtime.HubSync
		local function later(label, fn, ...)
			local args = table.pack(...)
			task.spawn(function() Util.SafeCall(label, fn, table.unpack(args, 1, args.n)) end)
		end
		local function linked() return ctx.Runtime.CloudLinked and sync.Quiet == 0 end

		local baseSave = manager.Save
		function manager:Save(name, ignoreRevision)
			local results = table.pack(baseSave(self, name, ignoreRevision))
			if results[1] and linked() then
				local saved = self:ResolveName(name or self.Account.SelectedConfig)
				if saved then later("hub push", push, ctx, saved) end
			end
			return table.unpack(results, 1, results.n)
		end
		local baseCreate = manager.Create
		function manager:Create(name)
			local results = table.pack(baseCreate(self, name))
			if results[1] and linked() then
				local created = self:ResolveName(name)
				if created then
					later("hub create", function()
						push(ctx, created)
						select(ctx, created)
					end)
				end
			end
			return table.unpack(results, 1, results.n)
		end
		local baseDelete = manager.Delete
		function manager:Delete(name)
			local resolved = self:ResolveName(name)
			local results = table.pack(baseDelete(self, name))
			if results[1] and resolved and linked() then
				sync.Synced[string.lower(resolved)] = nil
				later("hub delete", callApi, ctx, "DELETE", "/v1/hub/loader/configs/"
					.. HttpService:UrlEncode(resolved) .. "?placeId=" .. tostring(game.PlaceId))
			end
			return table.unpack(results, 1, results.n)
		end
		local baseLoad = manager.Load
		function manager:Load(name)
			local results = table.pack(baseLoad(self, name))
			if results[1] and linked() then later("hub select", select, ctx, self.Account.SelectedConfig) end
			local live = ctx.Runtime.HubLive
			if results[1] and live then later("hub hello", live.Hello, live) end
			return table.unpack(results, 1, results.n)
		end

		later("hub sync", CloudSync.Run, ctx)
	end

	return CloudSync
end
