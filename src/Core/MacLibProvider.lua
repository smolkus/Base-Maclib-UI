return function(Import)
	local Build = Import("Build")
	local Provider = {}
	local traceback = debug and debug.traceback or function(message) return tostring(message) end

	function Provider.Load()
		local source, lastError
		for attempt = 1, 3 do
			local ok, result = pcall(function() return game:HttpGet(Build.MacLibUrl) end)
			if ok and type(result) == "string" and #result > 10000 then source = result; break end
			lastError = ok and ("response was only " .. tostring(type(result) == "string" and #result or 0) .. " bytes") or result
			if attempt < 3 then task.wait(attempt * 0.2) end
		end
		assert(source, "Unable to download pinned MacLib source after 3 attempts: " .. tostring(lastError))
		local chunk, compileError = loadstring(source, "@MacLib")
		assert(chunk, "MacLib compile failed: " .. tostring(compileError))
		local ok, library = xpcall(chunk, traceback)
		assert(ok and type(library) == "table", "MacLib initialization failed: " .. tostring(library))
		return library
	end

	return Provider
end
