return function(Import)
	local Util = Import("Util")
	local CollectionService = game:GetService("CollectionService")
	local Lighting = game:GetService("Lighting")
	local RunService = game:GetService("RunService")
	local Workspace = game:GetService("Workspace")

	local Performance = {}

	local function disconnect(connection)
		if connection then pcall(function() connection:Disconnect() end) end
	end

	local function destroyEnemy(instance)
		if typeof(instance) ~= "Instance" or not instance.Parent then return end
		pcall(function() instance:Destroy() end)
	end

	function Performance:_SetDeleteEnemies(state, enabled)
		enabled = enabled == true
		if state.DeleteEnemies == enabled then return end
		state.DeleteEnemies = enabled
		disconnect(state.EnemyConnection)
		state.EnemyConnection = nil
		if not enabled then return end
		state.EnemyConnection = CollectionService:GetInstanceAddedSignal("Enemy"):Connect(destroyEnemy)
		for _, enemy in ipairs(CollectionService:GetTagged("Enemy")) do destroyEnemy(enemy) end
	end

	local function rememberAndSet(state, instance, property, value)
		local ok, current = pcall(function() return instance[property] end)
		if not ok or current == value then return end
		local properties = state.Originals[instance]
		if not properties then properties = {} state.Originals[instance] = properties end
		if properties[property] == nil then properties[property] = current end
		pcall(function() instance[property] = value end)
	end

	local function optimizeInstance(state, instance)
		if instance:IsA("BasePart") then
			rememberAndSet(state, instance, "CastShadow", false)
			rememberAndSet(state, instance, "Reflectance", 0)
		elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
			or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") then
			rememberAndSet(state, instance, "Enabled", false)
		elseif instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
			rememberAndSet(state, instance, "Enabled", false)
		elseif instance:IsA("PostEffect") then
			rememberAndSet(state, instance, "Enabled", false)
		end
	end

	function Performance:_SetFpsBoost(state, enabled)
		enabled = enabled == true
		if state.FpsBoost == enabled then return end
		state.FpsBoost = enabled
		disconnect(state.DescendantConnection)
		state.DescendantConnection = nil
		disconnect(state.LightingConnection)
		state.LightingConnection = nil
		if not enabled then
			for instance, properties in pairs(state.Originals) do
				if instance.Parent then
					for property, value in pairs(properties) do pcall(function() instance[property] = value end) end
				end
			end
			table.clear(state.Originals)
			return
		end

		rememberAndSet(state, Lighting, "GlobalShadows", false)
		rememberAndSet(state, Lighting, "EnvironmentDiffuseScale", 0)
		rememberAndSet(state, Lighting, "EnvironmentSpecularScale", 0)
		local terrain = Workspace:FindFirstChildOfClass("Terrain")
		if terrain then
			rememberAndSet(state, terrain, "Decoration", false)
			rememberAndSet(state, terrain, "WaterWaveSize", 0)
			rememberAndSet(state, terrain, "WaterWaveSpeed", 0)
			rememberAndSet(state, terrain, "WaterReflectance", 0)
		end
		for _, instance in ipairs(Workspace:GetDescendants()) do optimizeInstance(state, instance) end
		for _, instance in ipairs(Lighting:GetDescendants()) do optimizeInstance(state, instance) end
		state.DescendantConnection = Workspace.DescendantAdded:Connect(function(instance)
			if state.FpsBoost then optimizeInstance(state, instance) end
		end)
		state.LightingConnection = Lighting.DescendantAdded:Connect(function(instance)
			if state.FpsBoost then optimizeInstance(state, instance) end
		end)
	end

	function Performance:_SetRendering(ctx, state, enabled)
		enabled = enabled == true
		if state.RenderingDisabled == enabled then return end
		local method = RunService.Set3dRenderingEnabled
		if type(method) ~= "function" then
			state.RenderingDisabled = false
			if enabled then ctx.Runtime:Notify("Disable 3D Rendering", "This executor cannot access Set3dRenderingEnabled.") end
			if enabled and state.RenderingControl then
				task.defer(function() state.RenderingControl:UpdateState(false) end)
			end
			return
		end
		local ok, err = xpcall(function() method(RunService, not enabled) end, Util.Traceback)
		if not ok then
			state.RenderingDisabled = false
			if enabled then ctx.Runtime:Notify("Disable 3D Rendering", tostring(err)) end
			if enabled and state.RenderingControl then
				task.defer(function() state.RenderingControl:UpdateState(false) end)
			end
			return
		end
		state.RenderingDisabled = enabled
	end

	return {
		Name = "Performance",
		Version = 1,
		Priority = 12,
		Dependencies = {"Misc"},

		Init = function(self, ctx)
			local state = {
				DeleteEnemies = false,
				FpsBoost = false,
				RenderingDisabled = false,
				EnemyConnection = nil,
				DescendantConnection = nil,
				LightingConnection = nil,
				Originals = setmetatable({}, {__mode = "k"}),
			}
			local section = ctx.Tabs.MiscPerformance:Section({Side = "Left"})
			section:Header({Text = "Performance"})
			ctx.Registry:Toggle(section, {
				Name = "Delete Enemies",
				Default = false,
				Callback = function(value) Performance:_SetDeleteEnemies(state, value) end,
			}, "performance.delete_enemies")
			ctx.Registry:Toggle(section, {
				Name = "FPS Boost",
				Default = false,
				Callback = function(value) Performance:_SetFpsBoost(state, value) end,
			}, "performance.fps_boost")
			state.RenderingControl = ctx.Registry:Toggle(section, {
				Name = "Disable 3D Rendering",
				Default = false,
				Callback = function(value) Performance:_SetRendering(ctx, state, value) end,
			}, "performance.disable_3d_rendering")
			return state
		end,

		Disable = function(self, ctx, state)
			Performance:_SetDeleteEnemies(state, false)
			Performance:_SetFpsBoost(state, false)
			Performance:_SetRendering(ctx, state, false)
		end,

		Unload = function(self, ctx, state)
			disconnect(state.EnemyConnection)
			disconnect(state.DescendantConnection)
			disconnect(state.LightingConnection)
			state.EnemyConnection = nil
			state.DescendantConnection = nil
			state.LightingConnection = nil
			table.clear(state.Originals)
		end,
	}
end
