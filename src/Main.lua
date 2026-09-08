return function(Import)
	local Build = Import("Build")
	local Util = Import("Util")
	local Janitor = Import("Janitor")
	local FileSystem = Import("FileSystem")
	local ControlRegistry = Import("ControlRegistry")
	local ConfigManager = Import("ConfigManager")
	local ModuleManager = Import("ModuleManager")
	local UIManager = Import("UIManager")
	local MacLibProvider = Import("MacLibProvider")
	local SessionManager = Import("SessionManager")
	local PerformanceModule = Import("Performance")
	local SettingsModule = Import("Settings")
	local MiscModule = Import("Misc")
	local MobileButtonModule = Import("MobileButton")

	local Players = game:GetService("Players")
	local CoreGui = game:GetService("CoreGui")
	local LocalPlayer = Players.LocalPlayer
	local Environment = (getgenv and getgenv()) or _G

	-- Re-execution safety: an older runtime (from any previous version) is
	-- shut down fully - every module disabled, every connection and GUI it
	-- owned destroyed - before this one starts. Features added in newer
	-- versions therefore can never double-run against stale state.
	local previousRuntime = rawget(Environment, "__BASE_HUB_RUNTIME")
	if type(previousRuntime) == "table" and type(previousRuntime.Shutdown) == "function" then
		pcall(function()
			previousRuntime:Shutdown("re-executed")
		end)
		task.wait()
	end
	local generation = (tonumber(rawget(Environment, "__BASE_HUB_GENERATION")) or 0) + 1
	Environment.__BASE_HUB_GENERATION = generation

	local Runtime = {
		Alive = true,
		ShuttingDown = false,
		Janitor = Janitor.new(),
		Window = nil,
		MacGui = nil,
		Build = Build,
		Generation = generation,
	}
	Environment.__BASE_HUB_RUNTIME = Runtime

	function Runtime:Notify(title, description)
		local restoreIdentity = Util.ElevateIdentity()
		if self.Window then
			Util.SafeCall("notification", self.Window.Notify, self.Window, {
				Title = tostring(title),
				Description = tostring(description),
				Lifetime = 5,
			})
		else
			Util.Warn(title .. ": " .. description)
		end
		restoreIdentity()
	end

	function Runtime:Shutdown(reason, windowAlreadyUnloaded)
		if self.ShuttingDown then
			return
		end
		local restoreIdentity = Util.ElevateIdentity()
		self.ShuttingDown = true
		if self.Registry then
			self.Registry.OnChanged = nil
		end
		self.Alive = false
		if reason == "manual unload" and self.Config and self.Config.Account then
			self.Config.Account.Session.AutoExecute = false
			self.Config.AccountDirty = true
			local accountOk, accountError = self.Config:SaveAccount(true)
			if not accountOk then
				Util.Warn("disable auto execute failed: " .. tostring(accountError))
			end
		end
		if self.Modules then
			self.Modules:DestroyAll()
		end
		if self.Session then
			self.Session:Destroy()
		end
		if self.UIManager then
			self.UIManager:Destroy()
		end
		if self.Config then
			local flushOk, flushError = self.Config:Flush(true)
			if not flushOk then
				Util.Warn("final config flush failed: " .. tostring(flushError))
			end
			self.Config:Destroy()
		end
		self.Janitor:Cleanup()
		if self.Window and not windowAlreadyUnloaded then
			Util.SafeCall("disable old UI keybind", self.Window.SetKeybind, self.Window, Enum.KeyCode.Unknown)
			Util.SafeCall("unload old window", self.Window.Unload, self.Window)
		end
		if self.MacGui and self.MacGui.Parent then
			Util.SafeCall("destroy MacLib GUI", self.MacGui.Destroy, self.MacGui)
		end
		if rawget(Environment, "__BASE_HUB_RUNTIME") == self then
			Environment.__BASE_HUB_RUNTIME = nil
		end
		self.Reason = reason
		restoreIdentity()
	end

	local function guiParent()
		if type(gethui) == "function" then
			local ok, value = pcall(gethui)
			if ok then
				return value
			end
		end
		return CoreGui
	end

	local function captureChildren(parent)
		local output = {}
		for _, child in ipairs(parent:GetChildren()) do
			output[child] = true
		end
		return output
	end

	-- Destroy leftovers from a previous session whose shutdown never ran
	-- (executor crash, game closed mid-frame): the MacLib gui and the mobile
	-- button both use reserved names so they can always be reclaimed.
	local function destroyReserved(parent, name)
		local existing = parent:FindFirstChild(name)
		if existing then
			pcall(existing.Destroy, existing)
		end
	end

	local parent = guiParent()
	destroyReserved(parent, "BaseHub_MacLib")
	destroyReserved(parent, "BaseHub_MobileLauncher")
	local beforeGui = captureChildren(parent)

	local FileStore = FileSystem.new(Build.DataRoot)
	local Registry = ControlRegistry.new()
	Runtime.Registry = Registry
	local Config = ConfigManager.new(FileStore, Registry, LocalPlayer)
	Runtime.Config = Config
	local configOk, configError = Config:Initialize()
	if not configOk then
		Runtime:Shutdown("config initialization failed", true)
		error(configError)
	end

	local MacLib = MacLibProvider.Load()
	Runtime.MacLib = MacLib
	local deviceClass = UIManager.DeviceClass()
	local baseSize = UIManager.BaseSize(deviceClass)
	local accountKey = Enum.KeyCode[tostring(Config.Account.UI.ToggleKey)] or Enum.KeyCode.RightShift
	local Window = MacLib:Window({
		Title = Build.Name,
		Subtitle = "v" .. Build.Version,
		Size = baseSize,
		DragStyle = 1,
		DisabledWindowControls = {},
		ShowUserInfo = false,
		Keybind = accountKey,
		AcrylicBlur = Config.Account.UI.UIBlur == true,
	})
	Runtime.Window = Window
	local ResponsiveUI = UIManager.new(Window, Config.Account, Build)
	Runtime.UIManager = ResponsiveUI

	for _, child in ipairs(parent:GetChildren()) do
		if not beforeGui[child] and child:IsA("ScreenGui") then
			Runtime.MacGui = child
			child.Name = "BaseHub_MacLib"
			break
		end
	end

	local TabGroup = Window:TabGroup()
	local Tabs = {
		Misc = TabGroup:Tab({ Name = "Misc", Image = "rbxassetid://10734950309" }),
		Settings = TabGroup:Tab({ Name = "Settings", Image = "rbxassetid://10734950020" }),
	}
	local MiscPages = Tabs.Misc:SubTabGroup()
	Tabs.MiscSession = MiscPages:SubTab({ Name = "Session", Columns = 2 })
	Tabs.MiscPerformance = MiscPages:SubTab({ Name = "Performance", Columns = 2 })

	local Context = {
		Runtime = Runtime,
		Window = Window,
		MacLib = MacLib,
		Tabs = Tabs,
		Registry = Registry,
		Config = Config,
		FileSystem = FileStore,
		Player = LocalPlayer,
		Build = Build,
		UIManager = ResponsiveUI,
	}
	local Session = SessionManager.new(Runtime, Config)
	Context.Session = Session
	Runtime.Session = Session

	local Modules = ModuleManager.new(Context)
	Runtime.Modules = Modules
	Modules:Register(PerformanceModule)
	Modules:Register(SettingsModule)
	Modules:Register(MiscModule)
	Modules:Register(MobileButtonModule)

	local modulesOk, modulesError = Modules:LoadAll()
	if not modulesOk then
		Runtime:Shutdown("module load failure")
		error(modulesError)
	end

	local profileReady = true
	if Config.Account.AutoLoadSelected then
		local ok, err = Config:Load(Config.Account.SelectedConfig)
		if not ok then
			profileReady = false
			Config.LastLoadError = tostring(err)
			Runtime:Notify("Config load failed", tostring(err))
			Registry:Apply({})
		end
	else
		Registry:Apply({})
	end
	if profileReady then Config:ActivateProfile() end
	Registry.OnChanged = function()
		Config:ScheduleAutoSave()
	end

	if Config.Account.UI.HiddenOnLoad == true then
		Window:SetState(false)
	end
	Window.onUnloaded(function()
		Runtime:Shutdown("window unloaded", true)
	end)
	Tabs.Misc:Select()
	if profileReady then
		Runtime:Notify("Loaded", string.format("Account %s | Config %s", LocalPlayer.Name, Config.Account.SelectedConfig))
	end

	return Runtime
end
