return function(Import)
	local Players = game:GetService("Players")
	local HubReadouts = {}

	local LIMIT = 12

	local function leaderstats(out)
		local stats = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("leaderstats")
		if not stats then return end
		for _, child in ipairs(stats:GetChildren()) do
			if child:IsA("ValueBase") then
				local value = child.Value
				if type(value) == "number" or type(value) == "string" then
					table.insert(out, {name = child.Name, value = value, progress = type(value) == "number" or nil})
				end
			end
		end
	end

	function HubReadouts.Collect(runtime)
		local out = {}
		leaderstats(out)
		for _, provider in ipairs(runtime.Readouts or {}) do
			local ok, result = pcall(provider)
			if ok and type(result) == "table" then
				if result.name ~= nil then result = {result} end
				for _, item in ipairs(result) do
					if type(item) == "table" and item.name ~= nil then table.insert(out, item) end
				end
			end
		end
		table.insert(out, {name = "FPS", value = math.floor(workspace:GetRealPhysicsFPS())})
		while #out > LIMIT do table.remove(out, #out - 1) end
		return out
	end

	return HubReadouts
end
