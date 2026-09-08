
local REPOSITORIES = {
	"https://jexvral.xyz/game/base/",
	"https://raw.githubusercontent.com/Byorl/Base-Maclib-UI/main/",
}
local traceback = debug and debug.traceback or function(message) return tostring(message) end
local Environment = (getgenv and getgenv()) or _G

local function diagnostic(phase, moduleName, path, message)
	local record = {
		Phase = tostring(phase),
		Module = moduleName and tostring(moduleName) or nil,
		Path = path and tostring(path) or nil,
		Message = tostring(message),
		OccurredAt = os.time(),
	}
	Environment.__BASE_HUB_LAST_ERROR = record
	local context = {"[Base Hub] " .. record.Phase .. " failed"}
	if record.Module then table.insert(context, "Module: " .. record.Module) end
	if record.Path then table.insert(context, "Source: " .. record.Path) end
	table.insert(context, record.Message)
	return table.concat(context, "\n")
end

local function fail(phase, moduleName, path, message)
	error(diagnostic(phase, moduleName, path, message), 0)
end

local gameLoadDeadline = os.clock() + 30
local loadStateOk, gameLoaded = pcall(function() return game:IsLoaded() end)
while loadStateOk and not gameLoaded and os.clock() < gameLoadDeadline do
	task.wait(0.05)
	loadStateOk, gameLoaded = pcall(function() return game:IsLoaded() end)
end
if loadStateOk and not gameLoaded then
	fail("startup", "Roblox", nil, "The client did not finish loading within 30 seconds")
end

local function fetch(path, cacheBuster)
	local lastError
	local isAbsolute = string.match(path, "^https?://") ~= nil
	for repositoryIndex, repository in ipairs(REPOSITORIES) do
		local url = isAbsolute and path or (repository .. path)
		if cacheBuster then url = url .. "?v=" .. tostring(cacheBuster) end
		for attempt = 1, 2 do
			local ok, body = pcall(function() return game:HttpGet(url) end)
			if ok and type(body) == "string" and #body > 0 then
				local preview = body:sub(1, 240):lower()
				local rejected = preview:find("too many requests", 1, true)
					or preview:find("source gateway is busy", 1, true)
					or preview:find("source host returned http", 1, true)
					or preview:find("source request timed out", 1, true)
					or preview:find("unable to retrieve source", 1, true)
					or preview:find("<!doctype", 1, true)
					or preview:find("<html", 1, true)
				if not rejected then return body end
				lastError = string.format("%s returned an error document: %s", url, body:sub(1, 160):gsub("[%c]+", " "))
			else
				lastError = string.format("%s: %s", url, ok and "empty/non-text response" or tostring(body))
			end
			if attempt < 2 then task.wait(0.15 * attempt) end
		end
		if isAbsolute then break end
		if repositoryIndex < #REPOSITORIES then task.wait() end
	end
	fail("download", nil, path, string.format("All source endpoints failed: %s", tostring(lastError)))
end

local manifestSource = fetch("manifest.lua", os.time())
local manifestChunk, manifestCompileError = loadstring(manifestSource, "@Base-Hub/manifest.lua")
if not manifestChunk then fail("compile", "Manifest", "manifest.lua", manifestCompileError) end
local manifestOk, manifest = xpcall(manifestChunk, traceback)
if not manifestOk then fail("execute", "Manifest", "manifest.lua", manifest) end
if type(manifest) ~= "table" then fail("validate", "Manifest", "manifest.lua", "Manifest must return a table") end
if type(manifest.Entry) ~= "string" then fail("validate", "Manifest", "manifest.lua", "Manifest Entry must be a string") end
if type(manifest.Modules) ~= "table" then fail("validate", "Manifest", "manifest.lua", "Manifest Modules must return a table") end

-- Module paths may nest arbitrarily deep under the repository root
-- (e.g. "src/Core/AutomationCatalog.lua" or
-- "src/Modules/AutoFarm/Sigma/Layers/AutoClaim.lua"); the path is appended
-- verbatim to each repository base. Absolute https URLs are also allowed and
-- are fetched as-is. Anything that could escape the repository root is
-- rejected instead of being sent to the network.
local function normalizeModulePath(name, path)
	if type(path) ~= "string" or path == "" then
		fail("validate", name, path, "Module path must be a non-empty string")
	end
	if string.match(path, "^https?://") then
		return path
	end
	local normalized = path:gsub("\\", "/")
	normalized = normalized:gsub("^%./+", ""):gsub("^/+", "")
	if normalized == "" or string.find(normalized, "../", 1, true) or string.find(normalized, "/../", 1, true) then
		fail("validate", name, path, "Module paths must stay inside the repository root")
	end
	for segment in string.gmatch(normalized, "[^/]+") do
		if segment == "." or segment == ".." then
			fail("validate", name, path, "Module path segments must be plain folder or file names")
		end
	end
	return normalized
end

local jobs = {}
for name, path in pairs(manifest.Modules) do
	if type(name) ~= "string" or type(path) ~= "string" then
		fail("validate", "Manifest", "manifest.lua", "Manifest module entries must map names to paths")
	end
	local normalized = normalizeModulePath(name, path)
	manifest.Modules[name] = normalized
	table.insert(jobs, {Name = name, Path = normalized})
end
table.sort(jobs, function(a, b) return a.Name < b.Name end)

local sourceByPath, fetchErrors = {}, {}
local nextJob, completed = 1, 0
local workerCount = math.min(6, #jobs)
for _ = 1, workerCount do
	task.spawn(function()
		while true do
			local index = nextJob
			nextJob = nextJob + 1
			local job = jobs[index]
			if not job then return end
			local ok, sourceOrError = pcall(fetch, job.Path, manifest.Version)
			if ok then sourceByPath[job.Path] = sourceOrError
			else fetchErrors[job.Name] = tostring(sourceOrError) end
			completed = completed + 1
		end
	end)
end

local deadline = os.clock() + 25
while completed < #jobs and os.clock() < deadline do task.wait() end
if completed < #jobs then
	local pending = {}
	for _, job in ipairs(jobs) do
		if not sourceByPath[job.Path] and not fetchErrors[job.Name] then table.insert(pending, job.Name) end
	end
	fail("download", "Prefetch", nil, "Timed out after 25 seconds. Pending modules: " .. table.concat(pending, ", "))
end
if next(fetchErrors) then
	local messages = {}
	for _, job in ipairs(jobs) do
		if fetchErrors[job.Name] then table.insert(messages, job.Name .. ": " .. fetchErrors[job.Name]) end
	end
	fail("download", "Prefetch", nil, table.concat(messages, "\n"))
end

local loaded, loading, importStack = {}, {}, {}
local function Import(name)
	if loaded[name] ~= nil then return loaded[name] end
	if loading[name] then
		local chain = table.clone(importStack)
		table.insert(chain, tostring(name))
		fail("import", name, manifest.Modules[name], "Circular dependency: " .. table.concat(chain, " -> "))
	end
	local path = manifest.Modules[name]
	if type(path) ~= "string" then fail("import", name, nil, "Unknown source module") end

	loading[name] = true
	table.insert(importStack, name)
	local source = sourceByPath[path]
	if not source then fail("import", name, path, "Prefetched source is missing") end
	local chunk, compileError = loadstring(source, "@Base-Hub/" .. path)
	if not chunk then
		loading[name] = nil
		table.remove(importStack)
		fail("compile", name, path, compileError)
	end
	local chunkOk, factory = xpcall(chunk, traceback)
	if not chunkOk then
		loading[name] = nil
		table.remove(importStack)
		fail("chunk execution", name, path, factory)
	end
	local result = factory
	if type(factory) == "function" then
		local factoryOk, factoryResult = xpcall(function() return factory(Import) end, traceback)
		if not factoryOk then
			loading[name] = nil
			table.remove(importStack)
			fail("factory", name, path, factoryResult)
		end
		result = factoryResult
	end
	loading[name] = nil
	table.remove(importStack)
	loaded[name] = result
	return result
end

Environment.__BASE_HUB_IMPORT = Import
Environment.__BASE_HUB_MANIFEST = manifest

local entryOk, entryResult = xpcall(function()
	return Import(manifest.Entry)
end, traceback)
if not entryOk then
	if type(Environment.__BASE_HUB_LAST_ERROR) ~= "table" then
		Environment.__BASE_HUB_LAST_ERROR = {
			Phase = "startup",
			Module = manifest.Entry,
			Path = manifest.Modules[manifest.Entry],
			Message = tostring(entryResult),
			OccurredAt = os.time(),
		}
	end
	error(tostring(entryResult), 0)
end
Environment.__BASE_HUB_LAST_ERROR = nil
return entryResult
