return function(Import)
	local Build = Import("Build")
	local Util = Import("Util")
	local ConfigManager = {}
	ConfigManager.__index = ConfigManager

	local ACCOUNT_SCHEMA = 3
	local CONFIG_SCHEMA = 3

	local function mergeDefaults(target, defaults)
		target = type(target) == "table" and target or {}
		for key, default in pairs(defaults) do
			if type(default) == "table" then
				target[key] = mergeDefaults(target[key], default)
			elseif target[key] == nil then
				target[key] = default
			end
		end
		return target
	end

	local function ownerFromFlag(flag)
		local prefix = string.match(tostring(flag), "^([^.]+)") or "Core"
		return string.upper(string.sub(prefix, 1, 1)) .. string.sub(prefix, 2)
	end

	function ConfigManager.new(fileSystem, registry, player)
		local self = setmetatable({}, ConfigManager)
		self.FileSystem = fileSystem
		self.Registry = registry
		self.Player = player
		self.ConfigFolder = Build.DataRoot .. "/configs/global"
		self.AccountFolder = Build.DataRoot .. "/accounts/" .. tostring(player.UserId)
		self.AccountPath = self.AccountFolder .. "/state.json"
		self.Account = self:_DefaultAccount()
		self.KnownRevisions = {}
		self.SaveNonce = 0
		self.SaveInProgress = false
		self.PendingFlush = false
		self.ConfigDirty = false
		self.AccountDirty = false
		self.ProfileReady = false
		self.Alive = true
		self.DelayedTasks = {}
		return self
	end

	function ConfigManager:_DefaultAccount()
		return {
			Schema = ACCOUNT_SCHEMA,
			Revision = 0,
			UserId = self and self.Player.UserId or 0,
			UserName = self and self.Player.Name or "Unknown",
			SelectedConfig = "main",
			AutoLoadSelected = true,
			AutoSave = false,
			UI = {
				HiddenOnLoad = false,
				ToggleKey = "RightShift",
				Scale = {Desktop = 0.9, Mobile = 0.62},
				MobileLauncher = {X = 0.96, Y = 0.86},
				MobileLauncherPositions = {},
				UIBlur = false,
				HidePrivateInfo = true,
			},
			Session = {AutoExecute = false, AutoReconnect = false},
		}
	end

	function ConfigManager:_ConfigPath(name)
		return self.ConfigFolder .. "/" .. name .. ".json"
	end

	function ConfigManager:SanitizeName(name)
		name = tostring(name or "")
		name = string.gsub(name, "^%s+", "")
		name = string.gsub(name, "%s+$", "")
		name = string.gsub(name, "[<>:\"/\\|%?%*%c]", "_")
		name = string.gsub(name, "%s+", " ")
		name = string.gsub(name, "^[%. ]+", "")
		name = string.gsub(name, "[%. ]+$", "")
		if #name > 64 then name = string.sub(name, 1, 64) end
		return name
	end

	function ConfigManager:List()
		local names, seen = {}, {}
		for _, path in ipairs(self.FileSystem:List(self.ConfigFolder)) do
			local normalized = string.gsub(path, "\\", "/")
			local lowerPath = string.lower(normalized)
			local isBackup = string.match(lowerPath, "%.bak%.json$") or string.match(lowerPath, "%.json%.bak$")
			if isBackup then
				self.FileSystem:Delete(path)
			else
				local name = string.match(normalized, "([^/]+)%.json$")
				local lowerName = name and string.lower(name) or ""
				if name and not string.match(lowerName, "%.tmp$") and not string.match(lowerName, "%.bak$")
					and not seen[lowerName] then
					seen[lowerName] = true
					table.insert(names, name)
				end
			end
		end
		table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
		return names
	end

	function ConfigManager:ResolveName(name)
		local wanted = string.lower(self:SanitizeName(name))
		for _, existing in ipairs(self:List()) do
			if string.lower(existing) == wanted then return existing end
		end
		return nil
	end

	function ConfigManager:Exists(name)
		return self:ResolveName(name) ~= nil
	end

	function ConfigManager:_MigrateAccount(account)
		local legacyHiddenOnLoad = type(account) == "table"
			and type(account.UI) == "table"
			and account.UI.HiddenOnLoad == nil
			and account.UI.HiddenOnExecute == true
		account = mergeDefaults(type(account) == "table" and account or {}, self:_DefaultAccount())
		account.Schema = ACCOUNT_SCHEMA
		account.UserId = self.Player.UserId
		account.UserName = self.Player.Name
		account.UI.Scale = type(account.UI.Scale) == "table" and account.UI.Scale or {
			Desktop = tonumber(account.UI.Scale) or 0.9,
			Mobile = 0.62,
		}
		account.UI.Scale.Desktop = tonumber(account.UI.Scale.Desktop) or 0.9
		account.UI.Scale.Mobile = tonumber(account.UI.Scale.Mobile) or 0.62
		account.UI.MobileLauncher = type(account.UI.MobileLauncher) == "table"
			and account.UI.MobileLauncher or {X = 0.96, Y = 0.86}
		account.UI.MobileLauncher.X = math.clamp(tonumber(account.UI.MobileLauncher.X) or 0.96, 0, 1)
		account.UI.MobileLauncher.Y = math.clamp(tonumber(account.UI.MobileLauncher.Y) or 0.86, 0, 1)
		if legacyHiddenOnLoad then account.UI.HiddenOnLoad = true end
		account.UI.HiddenOnExecute = nil
		return account
	end

	function ConfigManager:_MigrateConfig(data, name)
		if type(data) ~= "table" then return nil, "config root is not a JSON object" end
		if tonumber(data.Schema) == 2 and type(data.Values) == "table" then
			local modules = {}
			for flag, value in pairs(data.Values) do
				if flag ~= "settings.ui_scale" and flag ~= "settings.ui_keybind" then
					local owner = ownerFromFlag(flag)
					modules[owner] = modules[owner] or {Version = 1, Values = {}}
					modules[owner].Values[flag] = Util.Clone(value)
				end
			end
			data.Modules = modules
			data.Values = nil
		end
		if type(data.Modules) ~= "table" then return nil, "missing Modules object" end
		for moduleName, moduleData in pairs(data.Modules) do
			if type(moduleName) ~= "string" or type(moduleData) ~= "table" or type(moduleData.Values) ~= "table" then
				return nil, "invalid module configuration at " .. tostring(moduleName)
			end
			moduleData.Version = tonumber(moduleData.Version) or 1
		end
		data.Schema = CONFIG_SCHEMA
		data.Name = name or data.Name
		data.Revision = math.max(tonumber(data.Revision) or 1, 1)
		data.Locked = nil
		data.LockedByUserId = nil
		data.LockedByUserName = nil
		return data
	end

	function ConfigManager:_FlattenModules(modules)
		local values = {}
		for _, moduleData in pairs(type(modules) == "table" and modules or {}) do
			for flag, value in pairs(type(moduleData.Values) == "table" and moduleData.Values or {}) do
				values[flag] = Util.Clone(value)
			end
		end
		return values
	end

	function ConfigManager:_ReadConfig(name)
		local data, sourceOrError = self.FileSystem:ReadJsonDetailed(self:_ConfigPath(name))
		if not data then return nil, sourceOrError ~= "" and sourceOrError or "config file is missing" end
		local migrated, migrationError = self:_MigrateConfig(data, name)
		if not migrated then return nil, "config migration failed: " .. tostring(migrationError) end
		return migrated, sourceOrError
	end

	function ConfigManager:_CheckRevision(name, data)
		local known = self.KnownRevisions[string.lower(name)]
		local current = tonumber(data.Revision) or 1
		if known and known ~= current then
			return false, string.format(
				"Config '%s' changed on disk (loaded revision %d, current revision %d). Load it again before saving.",
				name, known, current
			)
		end
		return true
	end

	function ConfigManager:Initialize()
		if not self.FileSystem.Available then
			return false, "Your executor does not expose the filesystem APIs required for configs."
		end
		local configFolderOk, configFolderError = self.FileSystem:EnsureFolder(self.ConfigFolder)
		if not configFolderOk then return false, configFolderError end
		local accountFolderOk, accountFolderError = self.FileSystem:EnsureFolder(self.AccountFolder)
		if not accountFolderOk then return false, accountFolderError end

		local loaded = self.FileSystem:ReadJson(self.AccountPath, self:_DefaultAccount())
		self.Account = self:_MigrateAccount(loaded)

		local names = self:List()
		if #names == 0 then
			local ok, err = self:Create("main")
			if not ok then return false, err end
			names = self:List()
		end
		local selected = self:ResolveName(self.Account.SelectedConfig)
		self.Account.SelectedConfig = selected or names[1] or "main"
		return self:SaveAccount(true)
	end

	function ConfigManager:SaveAccount(force)
		if not force and not self.AccountDirty then self.AccountDirty = true end
		self.Account.Schema = ACCOUNT_SCHEMA
		self.Account.Revision = (tonumber(self.Account.Revision) or 0) + 1
		self.Account.UpdatedAt = os.time()
		local ok, err = self.FileSystem:WriteJson(self.AccountPath, self.Account)
		if ok then self.AccountDirty = false end
		return ok, err
	end

	function ConfigManager:UpdateAccount(mutator, saveNow)
		local ok, err = xpcall(function() mutator(self.Account) end, Util.Traceback)
		if not ok then return false, "account update failed: " .. tostring(err) end
		self.AccountDirty = true
		if saveNow == true then return self:SaveAccount(true) end
		if self.Account.AutoSave then self:ScheduleAccountSave() end
		return true
	end

	function ConfigManager:_NewConfig(name)
		local now = os.time()
		return {
			Schema = CONFIG_SCHEMA,
			Name = name,
			Revision = 1,
			OwnerUserId = self.Player.UserId,
			OwnerUserName = self.Player.Name,
			CreatedAt = now,
			UpdatedAt = now,
			SavedAt = now,
			LastSavedByUserId = self.Player.UserId,
			LastSavedByUserName = self.Player.Name,
			PlaceId = Build.PlaceId,
			Modules = self.Registry:SnapshotModules(),
		}
	end

	function ConfigManager:Create(name)
		name = self:SanitizeName(name)
		if name == "" then return false, "Config name cannot be empty." end
		if self:Exists(name) then return false, "A config with that name already exists (names are case-insensitive)." end
		local data = self:_NewConfig(name)
		local ok, err = self.FileSystem:WriteJson(self:_ConfigPath(name), data)
		if ok then
			self.KnownRevisions[string.lower(name)] = data.Revision
			self.Account.SelectedConfig = name
			self:SaveAccount(true)
		end
		return ok, err
	end

	function ConfigManager:Delete(name)
		if #self:List() <= 1 then return false, "At least one config must exist. The last config cannot be deleted." end
		name = self:ResolveName(name)
		if not name then return false, "Selected config does not exist." end
		local data, readError = self:_ReadConfig(name)
		if not data then return false, "Cannot delete config: " .. tostring(readError) end
		local ok, err = self.FileSystem:Delete(self:_ConfigPath(name))
		if not ok then return false, err end
		self.KnownRevisions[string.lower(name)] = nil
		if string.lower(self.Account.SelectedConfig) == string.lower(name) then self.Account.SelectedConfig = self:List()[1] end
		self:SaveAccount(true)
		return true
	end

	function ConfigManager:SetSelected(name)
		local resolved = type(name) == "string" and self:ResolveName(name) or nil
		if not resolved then return false, "Invalid config selection." end
		self.Account.SelectedConfig = resolved
		return self:SaveAccount(true)
	end

	function ConfigManager:Save(name, ignoreRevision)
		name = self:ResolveName(name or self.Account.SelectedConfig)
		if not name then return false, "Selected config does not exist." end
		local old, readError = self:_ReadConfig(name)
		if not old then return false, "Cannot save config: " .. tostring(readError) end
		if not ignoreRevision then
			local revisionOk, revisionError = self:_CheckRevision(name, old)
			if not revisionOk then return false, revisionError end
		end

		local now = os.time()
		old.Schema = CONFIG_SCHEMA
		old.Name = name
		old.Revision = (tonumber(old.Revision) or 1) + 1
		old.UpdatedAt = now
		old.SavedAt = now
		old.LastSavedByUserId = self.Player.UserId
		old.LastSavedByUserName = self.Player.Name
		old.PlaceId = Build.PlaceId
		old.Locked = nil
		old.LockedByUserId = nil
		old.LockedByUserName = nil
		old.Modules = self.Registry:SnapshotModules()
		old.Values = nil
		local ok, err = self.FileSystem:WriteJson(self:_ConfigPath(name), old)
		if ok then
			self.KnownRevisions[string.lower(name)] = old.Revision
			self.ConfigDirty = false
		end
		return ok, err
	end

	function ConfigManager:Load(name)
		name = self:ResolveName(name or self.Account.SelectedConfig)
		if not name then return false, "Selected config does not exist." end
		local data, readError = self:_ReadConfig(name)
		if not data then return false, "Config is invalid or corrupted: " .. tostring(readError) end
		for moduleName, moduleData in pairs(data.Modules) do
			local supported = self.Registry.OwnerVersions[moduleName]
			if supported and moduleData.Version > supported then
				return false, string.format(
					"Config module '%s' uses version %d, but this script only supports version %d.",
					moduleName, moduleData.Version, supported
				)
			end
		end
		local previous = self.Registry:Snapshot()
		local values = self:_FlattenModules(data.Modules)
		local applyOk, applyError = self.Registry:ApplyAtomic(values)
		if applyOk and type(self.Registry.VerifyApplied) == "function" then
			local verifyOk, verifyError, verifyWarning = self.Registry:VerifyApplied()
			if verifyWarning and verifyWarning ~= "" then Util.Warn("config dropdown synchronization pending:\n" .. verifyWarning) end
			if not verifyOk then
				local retryOk, retryError = self.Registry:ApplyAtomic(values)
				local retryVerifyOk, retryVerifyError = false, "retry was not applied"
				if retryOk then
					local retryWarning
					retryVerifyOk, retryVerifyError, retryWarning = self.Registry:VerifyApplied()
					if retryWarning and retryWarning ~= "" then Util.Warn("config dropdown synchronization pending after retry:\n" .. retryWarning) end
				end
				if not retryOk or not retryVerifyOk then
					applyOk = false
					applyError = "post-load verification failed:\n" .. tostring(verifyError)
						.. "\nRetry failed:\n" .. tostring(retryError or retryVerifyError)
				end
			end
		end
		if not applyOk then
			local rollbackOk, rollbackError = self.Registry:ApplyAtomic(previous)
			return false, "Atomic config apply failed:\n" .. tostring(applyError)
				.. (rollbackOk and "\nPrevious state restored." or ("\nRollback also failed:\n" .. tostring(rollbackError)))
		end
		self.KnownRevisions[string.lower(name)] = data.Revision
		self.Account.SelectedConfig = name
		self.ConfigDirty = false
		self.LastLoadError = nil
		local accountOk, accountError = self:SaveAccount(true)
		if not accountOk then return false, "Config loaded, but account state could not be saved: " .. tostring(accountError) end
		return true, data
	end

	function ConfigManager:ActivateProfile()
		self.SaveNonce = self.SaveNonce + 1
		self.ConfigDirty = false
		self.ProfileReady = true
	end

	function ConfigManager:ScheduleAutoSave()
		if not self.ProfileReady then return end
		self.ConfigDirty = true
		if not self.Account.AutoSave or not self.Alive then return end
		self.SaveNonce = self.SaveNonce + 1
		local nonce = self.SaveNonce
		local delayed
		delayed = task.delay(0.35, function()
			if delayed then self.DelayedTasks[delayed] = nil end
			if self.Alive and self.Account.AutoSave and nonce == self.SaveNonce then
				local ok, err = self:Flush(true)
				if not ok then Util.Warn("auto-save flush failed: " .. tostring(err)) end
			end
		end)
		if delayed then self.DelayedTasks[delayed] = true end
	end

	function ConfigManager:ScheduleAccountSave()
		self.AccountDirty = true
		if not self.Account.AutoSave or not self.Alive then return end
		self.SaveNonce = self.SaveNonce + 1
		local nonce = self.SaveNonce
		local delayed
		delayed = task.delay(0.35, function()
			if delayed then self.DelayedTasks[delayed] = nil end
			if self.Alive and self.Account.AutoSave and nonce == self.SaveNonce then
				local ok, err = self:Flush(true)
				if not ok then Util.Warn("account auto-save flush failed: " .. tostring(err)) end
			end
		end)
		if delayed then self.DelayedTasks[delayed] = true end
	end

	function ConfigManager:Flush(respectAutoSave)
		self.SaveNonce = self.SaveNonce + 1
		if respectAutoSave == true and self.Account.AutoSave ~= true then return true end
		if self.SaveInProgress then
			self.PendingFlush = true
			return true
		end
		self.SaveInProgress = true
		local errors = {}
		repeat
			self.PendingFlush = false
			if self.ConfigDirty and self.ProfileReady then
				local configOk, configError = self:Save(self.Account.SelectedConfig)
				if not configOk then table.insert(errors, "config: " .. tostring(configError)) end
			end
			if self.AccountDirty then
				local accountOk, accountError = self:SaveAccount(true)
				if not accountOk then table.insert(errors, "account: " .. tostring(accountError)) end
			end
		until not self.PendingFlush
		self.SaveInProgress = false
		return #errors == 0, table.concat(errors, " | ")
	end

	function ConfigManager:Destroy()
		if not self.Alive then return true end
		local ok, err = self:Flush(true)
		self.Alive = false
		self.SaveNonce = self.SaveNonce + 1
		if type(task.cancel) == "function" then
			for delayed in pairs(self.DelayedTasks) do pcall(task.cancel, delayed) end
		end
		table.clear(self.DelayedTasks)
		return ok, err
	end

	return ConfigManager
end
