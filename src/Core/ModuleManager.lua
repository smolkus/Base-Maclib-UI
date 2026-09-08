return function(Import)
	local Janitor = Import("Janitor")
	local Util = Import("Util")
	local ModuleManager = {}
	ModuleManager.__index = ModuleManager

	local function lifecycleCall(name, stage, callback, ...)
		if type(callback) ~= "function" then return true end
		local arguments = table.pack(...)
		local ok, result = xpcall(function()
			return callback(table.unpack(arguments, 1, arguments.n))
		end, Util.Traceback)
		if not ok then
			return false, string.format("module '%s' failed during %s:\n%s", name, stage, tostring(result))
		end
		return true, result
	end

	function ModuleManager.new(context)
		return setmetatable({
			Definitions = {},
			Loaded = {},
			Dormant = {},
			States = {},
			Errors = {},
			Order = {},
			Context = context,
			ValidatedOrder = nil,
		}, ModuleManager)
	end

	function ModuleManager:Register(definition)
		assert(type(definition) == "table", "module definition must be a table")
		assert(type(definition.Name) == "string" and definition.Name ~= "", "module requires a non-empty Name")
		assert(self.Definitions[definition.Name] == nil, "duplicate module " .. definition.Name)
		assert(definition.Init == nil or type(definition.Init) == "function", "module " .. definition.Name .. " has invalid Init")
		assert(definition.Dependencies == nil or type(definition.Dependencies) == "table", "module " .. definition.Name .. " has invalid Dependencies")
		definition.Version = tonumber(definition.Version) or 1
		definition.Dependencies = definition.Dependencies or {}
		self.Definitions[definition.Name] = definition
		self.Context.Registry:SetOwnerVersion(definition.Name, definition.Version)
		self.States[definition.Name] = "Registered"
		self.ValidatedOrder = nil
		return definition
	end

	function ModuleManager:_SortedNames()
		local names = Util.SortedKeys(self.Definitions)
		table.sort(names, function(a, b)
			local left = self.Definitions[a].Priority or 100
			local right = self.Definitions[b].Priority or 100
			return left == right and a < b or left < right
		end)
		return names
	end

	function ModuleManager:ValidateGraph()
		local visiting, visited, stack, order = {}, {}, {}, {}
		local function visit(name)
			if visiting[name] then
				local start = table.find(stack, name) or 1
				local cycle = {}
				for index = start, #stack do table.insert(cycle, stack[index]) end
				table.insert(cycle, name)
				return false, "module dependency cycle: " .. table.concat(cycle, " -> ")
			end
			if visited[name] then return true end
			local definition = self.Definitions[name]
			if not definition then return false, "unknown module dependency '" .. tostring(name) .. "'" end
			visiting[name] = true
			table.insert(stack, name)
			for index, dependency in ipairs(definition.Dependencies) do
				if type(dependency) ~= "string" or dependency == "" then
					return false, string.format("module '%s' dependency #%d is not a valid module name", name, index)
				end
				if not self.Definitions[dependency] then
					return false, string.format("module '%s' depends on missing module '%s'", name, dependency)
				end
				local ok, err = visit(dependency)
				if not ok then return false, err end
			end
			table.remove(stack)
			visiting[name] = nil
			visited[name] = true
			table.insert(order, name)
			return true
		end
		for _, name in ipairs(self:_SortedNames()) do
			local ok, err = visit(name)
			if not ok then return false, err end
		end
		self.ValidatedOrder = order
		return true, order
	end

	function ModuleManager:_RecordFailure(name, message)
		self.States[name] = "Failed"
		self.Errors[name] = tostring(message)
		return false, tostring(message)
	end

	function ModuleManager:Load(name)
		if self.Loaded[name] then return true, self.Loaded[name].Result end
		if self.States[name] == "Failed" then return false, self.Errors[name] end
		local definition = self.Definitions[name]
		if not definition then return self:_RecordFailure(name, "unknown module '" .. tostring(name) .. "'") end
		if self.States[name] == "Loading" then return self:_RecordFailure(name, "module load re-entry detected for '" .. name .. "'") end
		self.States[name] = "Loading"

		for _, dependency in ipairs(definition.Dependencies) do
			local dependencyOk, dependencyError = self:Load(dependency)
			if not dependencyOk then
				return self:_RecordFailure(name, string.format("module '%s' dependency '%s' failed:\n%s", name, dependency, tostring(dependencyError)))
			end
		end

		local dormant = self.Dormant[name]
		if dormant then
			dormant.Janitor = Janitor.new()
			dormant.Context.ModuleJanitor = dormant.Janitor
			self.Context.Registry:SetOwnerActive(name, true)
			local applyOk, applyError = self.Context.Registry:ReapplyOwner(name)
			if not applyOk then
				self.Context.Registry:SetOwnerActive(name, false)
				return self:_RecordFailure(name, "module '" .. name .. "' state restore failed:\n" .. tostring(applyError))
			end
			local enableOk, enableError = lifecycleCall(name, "Enable", definition.Enable or definition.Start, definition, dormant.Context, dormant.Result)
			if not enableOk then
				dormant.Janitor:Cleanup()
				self.Context.Registry:SetOwnerActive(name, false)
				return self:_RecordFailure(name, enableError)
			end
			self.Dormant[name] = nil
			self.Loaded[name] = dormant
			table.insert(self.Order, name)
			self.States[name] = "Running"
			self.Errors[name] = nil
			return true, dormant.Result
		end

		local state = {Janitor = Janitor.new(), Definition = definition}
		local moduleContext = setmetatable({
			ModuleName = name,
			ModuleJanitor = state.Janitor,
			Registry = self.Context.Registry:Scope(name),
		}, {__index = self.Context})
		function moduleContext:RegisterCleanup(item, method) return state.Janitor:Add(item, method) end
		state.Context = moduleContext
		self.Context.Registry:SetOwnerActive(name, true)

		local initOk, resultOrError = lifecycleCall(name, "Init", definition.Init, definition, moduleContext)
		if not initOk then
			state.Janitor:Cleanup()
			self.Context.Registry:SetOwnerActive(name, false)
			return self:_RecordFailure(name, resultOrError)
		end
		state.Result = resultOrError

		local enableOk, enableError = lifecycleCall(name, "Enable", definition.Enable or definition.Start, definition, moduleContext, state.Result)
		if not enableOk then
			lifecycleCall(name, "rollback Unload", definition.Unload or definition.Destroy, definition, moduleContext, state.Result)
			state.Janitor:Cleanup()
			self.Context.Registry:SetOwnerActive(name, false)
			return self:_RecordFailure(name, enableError)
		end

		self.Loaded[name] = state
		table.insert(self.Order, name)
		self.States[name] = "Running"
		self.Errors[name] = nil
		return true, state.Result
	end

	function ModuleManager:Unload(name)
		local state = self.Loaded[name]
		if not state then return self.States[name] ~= "Failed", self.Errors[name] end
		self.States[name] = "Stopping"
		for loadedName, loadedState in pairs(self.Loaded) do
			if loadedName ~= name and table.find(loadedState.Definition.Dependencies, name) then
				local dependentOk, dependentError = self:Unload(loadedName)
				if not dependentOk then return self:_RecordFailure(name, "dependent unload failed: " .. tostring(dependentError)) end
			end
		end
		self.Context.Registry:SetOwnerActive(name, false)
		local definition = state.Definition
		local disableOk, disableError = lifecycleCall(name, "Disable", definition.Disable or definition.Stop, definition, state.Context, state.Result)
		state.Janitor:Cleanup()
		self.Loaded[name] = nil
		self.Dormant[name] = state
		local position = table.find(self.Order, name)
		if position then table.remove(self.Order, position) end
		if not disableOk then return self:_RecordFailure(name, disableError) end
		self.States[name] = "Dormant"
		return true
	end

	function ModuleManager:LoadAll()
		local graphOk, orderOrError = self:ValidateGraph()
		if not graphOk then return false, orderOrError end
		for _, name in ipairs(orderOrError) do
			local ok, err = self:Load(name)
			if not ok then return false, tostring(err) end
		end
		return true
	end

	function ModuleManager:UnloadAll()
		for index = #self.Order, 1, -1 do
			local ok, err = self:Unload(self.Order[index])
			if not ok then Util.Warn(err) end
		end
	end

	function ModuleManager:DestroyAll()
		for index = #self.Order, 1, -1 do
			local name = self.Order[index]
			local state = self.Loaded[name]
			if state then
				self.Context.Registry:SetOwnerActive(name, false)
				lifecycleCall(name, "Disable", state.Definition.Disable or state.Definition.Stop, state.Definition, state.Context, state.Result)
				lifecycleCall(name, "Unload", state.Definition.Unload or state.Definition.Destroy, state.Definition, state.Context, state.Result)
				state.Janitor:Cleanup()
				self.Loaded[name] = nil
				self.States[name] = "Destroyed"
			end
		end
		for name, state in pairs(self.Dormant) do
			self.Context.Registry:SetOwnerActive(name, false)
			lifecycleCall(name, "Unload dormant", state.Definition.Unload or state.Definition.Destroy, state.Definition, state.Context, state.Result)
			state.Janitor:Cleanup()
			self.Dormant[name] = nil
			self.States[name] = "Destroyed"
		end
		table.clear(self.Order)
	end

	function ModuleManager:GetStatus(name)
		return self.States[name], self.Errors[name]
	end

	return ModuleManager
end
