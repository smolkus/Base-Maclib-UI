return function(Import)
	local Util = Import("Util")
	local HttpService = game:GetService("HttpService")
	local Players = game:GetService("Players")
	local CloudSync = {}

	local function environment()
		return (getgenv and getgenv()) or _G
	end

	local function detectKey()
		local key = tostring(rawget(environment(), "key") or "")
		if string.match(key, "^jam_[%w]+$") then
			return key
		end
		return nil
	end

	local function executorRequest()
		local env = environment()
		if type(env.request) == "function" then return env.request end
		if type(env.http_request) == "function" then return env.http_request end
		if type(env.syn) == "table" and type(env.syn.request) == "function" then return env.syn.request end
		return nil
	end

	local function callApi(build, request, method, path, key, body)
		local ok, response = pcall(request, {
			Url = build.ApiUrl .. path,
			Method = method,
			Headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = "Bearer " .. key,
			},
			Body = body and HttpService:JSONEncode(body) or nil,
		})
		if not ok then
			return false, "request failed: " .. tostring(response)
		end
		local status = tonumber(type(response) == "table" and (response.StatusCode or response.Status)) or 0
		local decoded
		if type(response) == "table" and type(response.Body) == "string" and response.Body ~= "" then
			pcall(function()
				decoded = HttpService:JSONDecode(response.Body)
			end)
		end
		if status < 200 or status >= 300 then
			return false, (decoded and decoded.message) or ("HTTP " .. tostring(status))
		end
		return true, decoded
	end

	function CloudSync.Push(ctx, request, key, name)
		local data = ctx.Config:_ReadConfig(name)
		if type(data) ~= "table" then return false end
		local ok, result = CloudSync.Call(ctx, request, key, "PUT", name, data)
		return ok, result
	end

	function CloudSync.Call(ctx, request, key, method, name, data)
		return callApi(ctx.Build, request, method,
			"/hub/configs/" .. ctx.Build.GameCode .. "/" .. HttpService:UrlEncode(name), key, data)
	end

	function CloudSync.Run(ctx)
		local build = ctx.Build
		local key = detectKey()
		if not key then
			ctx.Runtime:Notify("Cloud", "No getgenv().key set; cloud sync skipped.")
			return
		end
		local request = executorRequest()
		if not request then
			ctx.Runtime:Notify("Cloud", "Executor has no HTTP request function; cloud sync skipped.")
			return
		end
		local linkOk, linkResult = callApi(build, request, "POST", "/hub/link", key, {
			gameCode = build.GameCode,
			placeId = game.PlaceId,
			robloxUserId = Players.LocalPlayer.UserId,
			robloxUsername = Players.LocalPlayer.Name,
		})
		if not linkOk then
			ctx.Runtime:Notify("Cloud", "Link failed: " .. tostring(linkResult))
			return
		end

		local pushed = 0
		for _, name in ipairs(ctx.Config:List()) do
			local pushOk = CloudSync.Push(ctx, request, key, name)
			if pushOk then pushed = pushed + 1 end
			task.wait()
		end

		local pulled = 0
		local listOk, list = callApi(build, request, "GET", "/hub/configs?game=" .. build.GameCode, key)
		if listOk and type(list.configs) == "table" then
			for _, item in ipairs(list.configs) do
				local cloudName = tostring(item.name)
				if not ctx.Config:Exists(cloudName) then
					local okOne, one = callApi(build, request, "GET",
						"/hub/configs/" .. build.GameCode .. "/" .. HttpService:UrlEncode(cloudName), key)
					if okOne and type(one.data) == "table" then
						local clean = ctx.Config:SanitizeName(cloudName)
						ctx.FileSystem:WriteJson(ctx.Config:_ConfigPath(clean), one.data)
						pulled = pulled + 1
					end
				end
				task.wait()
			end
		end

		ctx.Runtime.CloudLinked = true
		ctx.Runtime.CloudKey = key
		ctx.Runtime.CloudRequest = request
		ctx.Runtime:Notify("Cloud", ("Linked %s. Pushed %d config(s), pulled %d new."):format(
			tostring(linkResult.username or "account"), pushed, pulled))
	end

	function CloudSync.Start(ctx)
		local key = detectKey()
		if not key then return end
		local request = executorRequest()
		if not request then return end

		local config = ctx.Config
		local baseSave = config.Save
		function config:Save(name, ignoreRevision)
			local results = table.pack(baseSave(self, name, ignoreRevision))
			if ctx.Runtime.CloudLinked then
				task.spawn(function()
					Util.SafeCall("cloud push", CloudSync.Push, ctx, ctx.Runtime.CloudRequest or request, ctx.Runtime.CloudKey or key, tostring(name))
				end)
			end
			return table.unpack(results, 1, results.n)
		end

		task.spawn(function()
			Util.SafeCall("cloud sync", CloudSync.Run, ctx)
		end)
	end

	return CloudSync
end
