return function()
	local Util = {}
	Util.Traceback = debug and debug.traceback or function(message)
		return tostring(message)
	end

	function Util.Warn(message)
		warn("[Base Hub] " .. tostring(message))
	end

	function Util.SafeCall(label, callback, ...)
		if type(callback) ~= "function" then
			return true
		end
		local arguments = table.pack(...)
		local restoreIdentity = type(Util.ElevateIdentity) == "function" and Util.ElevateIdentity() or function() end
		local results = table.pack(xpcall(function()
			return callback(table.unpack(arguments, 1, arguments.n))
		end, Util.Traceback))
		restoreIdentity()
		if not results[1] then
			Util.Warn(label .. ": " .. tostring(results[2]))
		end
		return table.unpack(results, 1, results.n)
	end

	function Util.ElevateIdentity()
		local environment = _G
		if type(getgenv) == "function" then
			local ok, value = pcall(getgenv)
			if ok and type(value) == "table" then environment = value end
		end
		if type(environment) ~= "table" then return function() end end
		local setter = environment.setthreadidentity
			or environment.set_thread_identity
			or environment.setidentity
		local getter = environment.getthreadidentity
			or environment.get_thread_identity
			or environment.getidentity
		local synTable = environment.syn
		if not setter and type(synTable) == "table" then
			setter = synTable.set_thread_identity
		end
		if not getter and type(synTable) == "table" then
			getter = synTable.get_thread_identity
		end
		if type(setter) ~= "function" then
			return function() end
		end
		local hadPrevious, previous = false, nil
		if type(getter) == "function" then
			hadPrevious, previous = pcall(getter)
		end
		local elevated = pcall(setter, 8)
		if not elevated then
			pcall(setter, 7)
		end
		return function()
			if hadPrevious then
				pcall(setter, previous)
			end
		end
	end

	function Util.Clone(value, seen)
		if type(value) ~= "table" then
			return value
		end
		seen = seen or {}
		if seen[value] then
			return seen[value]
		end
		local output = {}
		seen[value] = output
		for key, child in pairs(value) do
			output[Util.Clone(key, seen)] = Util.Clone(child, seen)
		end
		return output
	end

	function Util.SortedKeys(dictionary)
		local keys = {}
		for key in pairs(dictionary) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return string.lower(tostring(a)) < string.lower(tostring(b))
		end)
		return keys
	end

	return Util
end
