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

	function CloudSync.Run(ctx)
		local ok, result = callApi(ctx, "POST", "/v1/hub/loader/hello", {
			placeId = tostring(game.PlaceId),
			jobId = tostring(game.JobId),
			user = {id = tostring(Players.LocalPlayer.UserId), name = Players.LocalPlayer.Name},
			values = HubLive.Plain(ctx.Registry:Snapshot()),
		})
		if not ok then
			ctx.Runtime:Notify("Hub", "Sync failed: " .. tostring(result))
			return
		end
		ctx.Runtime.CloudLinked = true
		local role = type(result.role) == "table" and result.role or {}
		local applied = HubLive.ApplyDesired(ctx, result.values, result.deviceOnly)
		ctx.Runtime.HubRole = {Name = role.name, Version = role.version}
		ctx.Runtime:Notify("Hub", applied
			and string.format("Role %s, version %s.", tostring(role.name), tostring(role.version))
			or "Some settings of the role could not be applied.")
		local live = HubLive.new(ctx, ctx.Runtime.Cloud.Key)
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
		ctx.Runtime.Readouts = ctx.Runtime.Readouts or {}

		local config = ctx.Config
		local baseLoad = config.Load
		function config:Load(name)
			local results = table.pack(baseLoad(self, name))
			local live = ctx.Runtime.HubLive
			if results[1] and live then
				task.spawn(function() Util.SafeCall("hub loaded", live.Loaded, live, self.Account.SelectedConfig) end)
			end
			return table.unpack(results, 1, results.n)
		end

		task.spawn(function() Util.SafeCall("hub sync", CloudSync.Run, ctx) end)
	end

	return CloudSync
end
