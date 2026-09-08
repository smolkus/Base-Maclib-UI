return function(Import)
	local Util = Import("Util")
	local HttpService = game:GetService("HttpService")
	local FileSystem = {}
	FileSystem.__index = FileSystem

	local function describe(path, operation, reason)
		return string.format("%s failed for '%s': %s", operation, tostring(path), tostring(reason))
	end

	local function sidecarPath(path, label)
		local stem = string.match(path, "^(.*)%.json$")
		if stem then return stem .. "." .. label .. ".json" end
		return path .. "." .. label .. ".json"
	end

	local function discardBackups(path)
		if type(delfile) ~= "function" then return end
		for _, backupPath in ipairs({sidecarPath(path, "bak"), path .. ".bak"}) do
			if isfile(backupPath) then pcall(delfile, backupPath) end
		end
	end

	function FileSystem.new(root)
		local self = setmetatable({Root = root}, FileSystem)
		self.Available = type(isfile) == "function"
			and type(readfile) == "function"
			and type(writefile) == "function"
			and type(isfolder) == "function"
			and type(makefolder) == "function"
			and type(listfiles) == "function"
		return self
	end

	function FileSystem:EnsureFolder(path)
		if not self.Available then return false, "executor filesystem APIs are unavailable" end
		local current = ""
		for segment in string.gmatch(path, "[^/\\]+") do
			current = current == "" and segment or (current .. "/" .. segment)
			if not isfolder(current) then
				local ok, err = pcall(makefolder, current)
				if not ok and not isfolder(current) then
					return false, describe(current, "create folder", err)
				end
			end
		end
		return true
	end

	function FileSystem:Read(path)
		if not self.Available or not isfile(path) then return nil end
		local ok, data = pcall(readfile, path)
		if not ok then return nil, describe(path, "read", data) end
		return data
	end

	function FileSystem:_WriteRaw(path, data)
		if not self.Available then return false, "executor filesystem APIs are unavailable" end
		local folder = string.match(path, "^(.*)[/\\][^/\\]+$")
		if folder then
			local folderOk, folderError = self:EnsureFolder(folder)
			if not folderOk then return false, folderError end
		end
		local ok, err = pcall(writefile, path, data)
		if not ok then return false, describe(path, "write", err) end
		return true
	end

	function FileSystem:Write(path, data)
		return self:_WriteRaw(path, data)
	end

	function FileSystem:Delete(path)
		if type(delfile) ~= "function" then return false, "delfile is unavailable" end
		if not isfile(path) then return true end
		local ok, err = pcall(delfile, path)
		if not ok then return false, describe(path, "delete", err) end
		return true
	end

	function FileSystem:List(path)
		if not self.Available or not isfolder(path) then return {} end
		local ok, files = pcall(listfiles, path)
		return ok and files or {}
	end

	function FileSystem:_DecodeJson(raw, path)
		if type(raw) ~= "string" or raw == "" then
			return nil, describe(path, "JSON decode", "file is empty")
		end
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if not ok or type(decoded) ~= "table" then
			return nil, describe(path, "JSON decode", ok and "root value is not an object" or decoded)
		end
		return decoded
	end

	function FileSystem:ReadJsonDetailed(path)
		discardBackups(path)
		local errors = {}
		local candidates = {
			path,
			sidecarPath(path, "tmp"),
			path .. ".tmp",
		}
		for _, candidate in ipairs(candidates) do
			local raw, readError = self:Read(candidate)
			if raw then
				local decoded, decodeError = self:_DecodeJson(raw, candidate)
				if decoded then
					if candidate ~= path then
						local repaired, repairError = self:_WriteRaw(path, raw)
						if not repaired then Util.Warn("config recovery succeeded but " .. tostring(repairError)) end
					end
					return decoded, candidate
				end
				table.insert(errors, decodeError)
			elseif readError then
				table.insert(errors, readError)
			end
		end
		return nil, table.concat(errors, " | ")
	end

	function FileSystem:ReadJson(path, fallback)
		local decoded = self:ReadJsonDetailed(path)
		return decoded or Util.Clone(fallback)
	end

	function FileSystem:WriteJson(path, value)
		discardBackups(path)
		local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, value)
		if not encodeOk then return false, describe(path, "JSON encode", encoded) end

		local temporaryPath = sidecarPath(path, "tmp")
		local tempOk, tempError = self:_WriteRaw(temporaryPath, encoded)
		if not tempOk then return false, tempError end

		local tempRaw, tempReadError = self:Read(temporaryPath)
		local tempDecoded, tempDecodeError = self:_DecodeJson(tempRaw, temporaryPath)
		if not tempRaw or tempRaw ~= encoded or not tempDecoded then
			return false, tempReadError or tempDecodeError or describe(temporaryPath, "verify", "content mismatch")
		end

		local writeOk, writeError = self:_WriteRaw(path, encoded)
		if not writeOk then return false, tostring(writeError) end
		local finalRaw, finalReadError = self:Read(path)
		local finalDecoded, finalDecodeError = self:_DecodeJson(finalRaw, path)
		if not finalRaw or finalRaw ~= encoded or not finalDecoded then
			return false, finalReadError or finalDecodeError or describe(path, "verify", "content mismatch")
		end

		if type(delfile) == "function" and isfile(temporaryPath) then pcall(delfile, temporaryPath) end
		return true
	end

	return FileSystem
end
