return function(Import)
	local Janitor = Import("Janitor")
	local Util = Import("Util")
	local UserInputService = game:GetService("UserInputService")
	local RunService = game:GetService("RunService")
	local TweenService = game:GetService("TweenService")
	local UIManager = {}
	UIManager.__index = UIManager

	local BASE_SIZE = {
		Desktop = Vector2.new(800, 600),
		Mobile = Vector2.new(620, 465),
	}

	local DEFAULT_SCALE = {
		Desktop = 0.9,
		Mobile = 0.62,
	}
	local LAUNCHER_SIZE = 52
	local LAUNCHER_MARGIN = 10

	local function clamp01(value, fallback)
		return math.clamp(tonumber(value) or fallback or 0, 0, 1)
	end

	local function elevated(callback, ...)
		local arguments = table.pack(...)
		local results = table.pack(xpcall(function()
			return callback(table.unpack(arguments, 1, arguments.n))
		end, Util.Traceback))
		if results[1] then return true, table.unpack(results, 2, results.n) end
		local firstError = results[2]
		local restoreIdentity = Util.ElevateIdentity()
		results = table.pack(xpcall(function()
			return callback(table.unpack(arguments, 1, arguments.n))
		end, Util.Traceback))
		restoreIdentity()
		if not results[1] then
			Util.Warn("mobile launcher: " .. tostring(firstError) .. "\nFallback: " .. tostring(results[2]))
			return false
		end
		return true, table.unpack(results, 2, results.n)
	end

	local function corner(parent, radius)
		local item = Instance.new("UICorner")
		item.CornerRadius = UDim.new(0, radius)
		item.Parent = parent
		return item
	end

	local function viewportSize()
		local camera = workspace.CurrentCamera
		return camera and camera.ViewportSize or Vector2.new(1280, 720)
	end

	function UIManager.DeviceClass()
		local viewport = viewportSize()
		return UserInputService.TouchEnabled and (not UserInputService.KeyboardEnabled or viewport.X < 800)
			and "Mobile" or "Desktop"
	end

	function UIManager.BaseSize(device)
		local size = BASE_SIZE[device or UIManager.DeviceClass()] or BASE_SIZE.Desktop
		return UDim2.fromOffset(size.X, size.Y)
	end

	-- Defaults track the screen: half the viewport height in design pixels,
	-- clamped so phones get a readable window and big monitors stay sane.
	function UIManager.DefaultScale(device)
		local size = BASE_SIZE[device or UIManager.DeviceClass()] or BASE_SIZE.Desktop
		local viewport = viewportSize()
		return math.clamp((viewport.Y * 0.5) / size.Y, 0.62, 1.2)
	end

	function UIManager.new(window, account, build)
		local device = UIManager.DeviceClass()
		local stored = type(account.UI) == "table" and type(account.UI.Scale) == "table"
			and tonumber(account.UI.Scale[device]) or nil
		local self = setmetatable({
			Window = window,
			Account = account,
			Device = device,
			BasePixels = BASE_SIZE[device],
			LauncherBrand = type(build) == "table" and (build.LauncherText or "HUB") or "HUB",
			RequestedScale = stored or UIManager.DefaultScale(device),
			CurrentScale = 0,
			TargetScale = 0,
			Janitor = Janitor.new(),
			Alive = true,
			Launcher = nil,
			LauncherGui = nil,
			LauncherPosition = nil,
			LauncherWindowState = nil,
			LauncherViewport = nil,
			LauncherStatus = nil,
			LauncherAccent = nil,
			LauncherPressScale = nil,
		}, UIManager)
		self.CurrentScale = self:_EffectiveScale(self.RequestedScale)
		self.TargetScale = self.CurrentScale
		window:SetScale(self.CurrentScale)

		self.Janitor:AddConnection(RunService.RenderStepped:Connect(function(deltaTime)
			if not self.Alive then return end
			if self.Launcher then
				local viewport = viewportSize()
				if viewport ~= self.LauncherViewport then
					self.LauncherViewport = viewport
					elevated(function()
						self:_SetLauncherPosition(self.LauncherPosition)
					end)
				end
			end
			self:_SyncLauncherState()
			local target = self:_EffectiveScale(self.RequestedScale)
			self.TargetScale = target
			local difference = target - self.CurrentScale
			if math.abs(difference) < 0.0005 then
				if self.CurrentScale ~= target then
					self.CurrentScale = target
					window:SetScale(target)
				end
				return
			end
			local alpha = 1 - math.exp(-math.min(deltaTime, 0.05) * 18)
			local step = math.clamp(difference * alpha, -0.018, 0.018)
			self.CurrentScale = self.CurrentScale + step
			window:SetScale(self.CurrentScale)
		end))
		return self
	end

	function UIManager:_LauncherBounds()
		local viewport = viewportSize()
		local half = LAUNCHER_SIZE * 0.5
		local inset = LAUNCHER_MARGIN + half
		local minimum = Vector2.new(inset, inset)
		local maximum = Vector2.new(math.max(inset, viewport.X - inset), math.max(inset, viewport.Y - inset))
		return minimum, maximum
	end

	function UIManager:_LauncherPixels(normalized)
		local minimum, maximum = self:_LauncherBounds()
		local x = clamp01(normalized and normalized.X, 0.96)
		local y = clamp01(normalized and normalized.Y, 0.86)
		return Vector2.new(
			minimum.X + ((maximum.X - minimum.X) * x),
			minimum.Y + ((maximum.Y - minimum.Y) * y)
		)
	end

	function UIManager:_LauncherNormalized(position)
		local minimum, maximum = self:_LauncherBounds()
		local width = math.max(1, maximum.X - minimum.X)
		local height = math.max(1, maximum.Y - minimum.Y)
		return {
			X = clamp01((position.X - minimum.X) / width, 0.96),
			Y = clamp01((position.Y - minimum.Y) / height, 0.86),
		}
	end

	function UIManager:_SetLauncherPosition(normalized)
		if not self.Launcher or not self.LauncherGui then return end
		self.LauncherPosition = {
			X = clamp01(normalized and normalized.X, 0.96),
			Y = clamp01(normalized and normalized.Y, 0.86),
		}
		local pixels = self:_LauncherPixels(self.LauncherPosition)
		self.Launcher.Position = UDim2.fromOffset(pixels.X, pixels.Y)
	end

	function UIManager:_SyncLauncherState()
		if not self.Launcher or not self.LauncherStatus or not self.LauncherAccent or not self.Window then return end
		local ok, visible = pcall(self.Window.GetState, self.Window)
		if not ok or visible == self.LauncherWindowState then return end
		self.LauncherWindowState = visible
		elevated(function()
			self.LauncherStatus.Text = visible and "HIDE" or "OPEN"
			self.LauncherAccent.BackgroundColor3 = visible
				and Color3.fromRGB(88, 201, 255) or Color3.fromRGB(173, 107, 255)
		end)
	end

	function UIManager:MountMobileLauncher(parent, config)
		if self.LauncherGui or not parent then return false end
		local viewport = viewportSize()
		local launcherSize = math.clamp(math.floor(math.max(viewport.Y * 0.06, viewport.X * 0.034)), 48, 112)
		local ui = type(self.Account.UI) == "table" and self.Account.UI or {}
		-- Position is per config profile: a brand new config starts at the
		-- standard spot, a saved one restores where the user last left it.
		local positions = type(ui.MobileLauncherPositions) == "table" and ui.MobileLauncherPositions or {}
		local configName = tostring(self.Account and self.Account.SelectedConfig or "main")
		local stored = (type(positions[configName]) == "table" and positions[configName])
			or {X = 0.96, Y = 0.86}
		local created
		local ok = elevated(function()
			local screen = Instance.new("ScreenGui")
			screen.Name = "BaseHub_MobileLauncher"
			screen.DisplayOrder = 1000000
			screen.Enabled = true
			screen.IgnoreGuiInset = false
			screen.ResetOnSpawn = false
			screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

			local shadow = Instance.new("Frame")
			shadow.Name = "Shadow"
			shadow.AnchorPoint = Vector2.new(0.5, 0.5)
			shadow.Position = UDim2.fromScale(0.5, 0.54)
			shadow.Size = UDim2.fromOffset(launcherSize + 4, launcherSize + 4)
			shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			shadow.BackgroundTransparency = 0.48
			shadow.BorderSizePixel = 0
			shadow.ZIndex = 1

			local button = Instance.new("TextButton")
			button.Name = "Launcher"
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Size = UDim2.fromOffset(launcherSize, launcherSize)
			button.BackgroundColor3 = Color3.fromRGB(18, 19, 23)
			button.BackgroundTransparency = 0.04
			button.BorderSizePixel = 0
			button.AutoButtonColor = false
			button.Text = ""
			button.Active = true
			button.ZIndex = 2
			button.Parent = screen
			shadow.Parent = button

			corner(button, 16)
			corner(shadow, 16)
			local stroke = Instance.new("UIStroke")
			stroke.Name = "Outline"
			stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			stroke.Color = Color3.fromRGB(78, 83, 96)
			stroke.Thickness = 1.4
			stroke.Transparency = 0.12
			stroke.Parent = button

			local gradient = Instance.new("UIGradient")
			gradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(31, 33, 40)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(14, 15, 18)),
			})
			gradient.Rotation = 135
			gradient.Parent = button

			local scale = Instance.new("UIScale")
			scale.Name = "PressScale"
			scale.Scale = 1
			scale.Parent = button

			local brand = Instance.new("TextLabel")
			brand.Name = "Brand"
			brand.BackgroundTransparency = 1
			brand.Position = UDim2.fromOffset(0, math.floor(launcherSize * 0.12))
			brand.Size = UDim2.new(1, 0, 0, math.floor(launcherSize * 0.44))
			brand.Font = Enum.Font.GothamBold
			brand.Text = self.LauncherBrand or "HUB"
			brand.TextColor3 = Color3.fromRGB(242, 244, 248)
			brand.TextSize = math.floor(launcherSize * 0.34)
			brand.ZIndex = 3
			brand.Parent = button

			local status = Instance.new("TextLabel")
			status.Name = "Status"
			status.BackgroundTransparency = 1
			status.Position = UDim2.fromOffset(0, math.floor(launcherSize * 0.54))
			status.Size = UDim2.new(1, 0, 0, math.floor(launcherSize * 0.22))
			status.Font = Enum.Font.GothamMedium
			status.Text = "HIDE"
			status.TextColor3 = Color3.fromRGB(158, 163, 174)
			status.TextSize = math.max(7, math.floor(launcherSize * 0.13))
			status.ZIndex = 3
			status.Parent = button

			local accent = Instance.new("Frame")
			accent.Name = "Accent"
			accent.AnchorPoint = Vector2.new(0.5, 1)
			accent.Position = UDim2.new(0.5, 0, 1, -math.max(4, math.floor(launcherSize * 0.1)))
			accent.Size = UDim2.fromOffset(math.floor(launcherSize * 0.37), 2)
			accent.BackgroundColor3 = Color3.fromRGB(88, 201, 255)
			accent.BorderSizePixel = 0
			accent.ZIndex = 3
			accent.Parent = button
			corner(accent, 2)

			self.LauncherGui = screen
			self.Launcher = button
			self.LauncherStatus = status
			self.LauncherAccent = accent
			self.LauncherPressScale = scale
			self.LauncherViewport = viewportSize()
			self:_SetLauncherPosition(stored)
			screen.Parent = parent
			created = screen
		end)
		if not ok or not created then return false end
		self.Janitor:AddInstance(created)

		local dragging = false
		local dragged = false
		local dragInput
		local dragStart
		local positionStart
		local suppressClickUntil = 0

		local function setPressed(pressed)
			elevated(function()
				local target = pressed and 0.92 or 1
				TweenService:Create(self.LauncherPressScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
					Scale = target,
				}):Play()
			end)
		end
		local function connect(source, signalName, callback)
			local connected, connection = elevated(function()
				return source[signalName]:Connect(callback)
			end)
			if connected and connection then self.Janitor:AddConnection(connection) end
		end

		connect(self.Launcher, "InputBegan", function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch
				and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
			dragging = true
			dragged = false
			dragInput = input
			dragStart = input.Position
			positionStart = self:_LauncherPixels(self.LauncherPosition)
			setPressed(true)
		end)

		connect(self.Launcher, "InputChanged", function(input)
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseMovement then
				dragInput = input
			end
		end)

		connect(UserInputService, "InputChanged", function(input)
			if not dragging or input ~= dragInput or not dragStart or not positionStart then return end
			local delta = input.Position - dragStart
			if delta.Magnitude >= 7 then dragged = true end
			if not dragged then return end
			elevated(function()
				local minimum, maximum = self:_LauncherBounds()
				local current = Vector2.new(
					math.clamp(positionStart.X + delta.X, minimum.X, maximum.X),
					math.clamp(positionStart.Y + delta.Y, minimum.Y, maximum.Y)
				)
				self.LauncherPosition = self:_LauncherNormalized(current)
				self.Launcher.Position = UDim2.fromOffset(current.X, current.Y)
			end)
		end)

		connect(UserInputService, "InputEnded", function(input)
			if not dragging then return end
			if input ~= dragInput and input.UserInputType ~= Enum.UserInputType.Touch
				and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
			dragging = false
			setPressed(false)
			if dragged then
				suppressClickUntil = os.clock() + 0.2
				local position = self.LauncherPosition
				local saveOk, saveError = config:UpdateAccount(function(account)
					account.UI.MobileLauncherPositions = account.UI.MobileLauncherPositions or {}
					account.UI.MobileLauncherPositions[tostring(account.SelectedConfig or "main")] = {X = position.X, Y = position.Y}
				end, true)
				if not saveOk then Util.Warn("mobile launcher position save failed: " .. tostring(saveError)) end
			end
			dragInput = nil
		end)

		connect(self.Launcher, "Activated", function()
			if os.clock() < suppressClickUntil or dragged or not self.Alive then return end
			elevated(function()
				self.Window:SetState(not self.Window:GetState())
				self.LauncherWindowState = nil
				self:_SyncLauncherState()
			end)
		end)

		self.LauncherWindowState = nil
		self:_SyncLauncherState()
		return true
	end

	function UIManager:_ViewportFit()
		local viewport = viewportSize()
		local safeWidth = math.max(1, viewport.X - (self.Device == "Mobile" and 16 or 36))
		local safeHeight = math.max(1, viewport.Y - (self.Device == "Mobile" and 28 or 54))
		return math.min(safeWidth / self.BasePixels.X, safeHeight / self.BasePixels.Y, 1.2)
	end

	function UIManager:_EffectiveScale(requested)
		requested = math.clamp(tonumber(requested) or UIManager.DefaultScale(self.Device), 0.35, 1.2)
		return math.min(requested, self:_ViewportFit())
	end

	function UIManager:GetRequestedScale()
		return self.RequestedScale
	end

	function UIManager:SetRequestedScale(scale, immediate)
		self.RequestedScale = math.clamp(tonumber(scale) or self.RequestedScale, 0.35, 1.2)
		self.TargetScale = self:_EffectiveScale(self.RequestedScale)
		if immediate == true then
			self.CurrentScale = self.TargetScale
			self.Window:SetScale(self.CurrentScale)
		end
		return self.RequestedScale, self.TargetScale
	end

	function UIManager:UnmountMobileLauncher()
		if self.LauncherGui then
			pcall(function() self.LauncherGui:Destroy() end)
		end
		self.Launcher = nil
		self.LauncherGui = nil
		self.LauncherStatus = nil
		self.LauncherAccent = nil
		self.LauncherPressScale = nil
	end

	function UIManager:Destroy()
		self.Alive = false
		self.Janitor:Cleanup()
		self.Launcher = nil
		self.LauncherGui = nil
		self.LauncherStatus = nil
		self.LauncherAccent = nil
		self.LauncherPressScale = nil
	end

	return UIManager
end
