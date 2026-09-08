return function(Import)
	local Util = Import("Util")
	local Players = game:GetService("Players")
	local UserInputService = game:GetService("UserInputService")
	local CoreGui = game:GetService("CoreGui")
	local MobileButton = {}

	local BUTTON_NAME = "BaseHub_MobileButton"

	local function guiParent()
		if type(gethui) == "function" then
			local ok, value = pcall(gethui)
			if ok then
				return value
			end
		end
		return CoreGui
	end

	local function destroyExisting(parent)
		local existing = parent:FindFirstChild(BUTTON_NAME)
		if existing then
			pcall(existing.Destroy, existing)
		end
	end

	-- Reclaims a button left behind by a crashed previous session so a fresh
	-- toggle never stacks duplicates.
	MobileButton.Reclaim = function(parent)
		destroyExisting(parent or guiParent())
	end

	function MobileButton:Create(ctx, state)
		self:Destroy(state)
		local parent = guiParent()
		destroyExisting(parent)

		local gui = Instance.new("ScreenGui")
		gui.Name = BUTTON_NAME
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 9999
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

		local button = Instance.new("TextButton")
		button.Name = "Toggle"
		button.AnchorPoint = Vector2.new(1, 1)
		button.Position = UDim2.new(1, -16, 1, -16)
		button.Size = UDim2.new(0, 136, 0, 42)
		button.BackgroundColor3 = Color3.fromRGB(14, 14, 17)
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Text = ctx.Build.Name
		button.TextColor3 = Color3.fromRGB(235, 235, 240)
		button.TextSize = 15
		button.Font = Enum.Font.GothamMedium

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(70, 70, 82)
		stroke.Thickness = 1
		stroke.Parent = button

		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(26, 26, 32)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 12, 15)),
		})
		gradient.Rotation = 90
		gradient.Parent = button

		button.Parent = gui
		gui.Parent = parent

		-- Drag handling covers both mouse and touch; a click (movement under
		-- the threshold) toggles the window through the same SetState path the
		-- keybind uses, so the two never desynchronize.
		local dragging = false
		local dragStart, startPos

		local function endDrag(input)
			if not dragging then
				return
			end
			dragging = false
			local delta = Vector2.new(input.Position.X - dragStart.X, input.Position.Y - dragStart.Y)
			if delta.Magnitude < 6 then
				local ok, windowState = pcall(function()
					return not ctx.Runtime.Window:GetState()
				end)
				if ok then
					pcall(function()
						ctx.Runtime.Window:SetState(windowState)
					end)
				end
			end
		end

		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = button.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						endDrag(input)
					end
				end)
			end
		end)

		UserInputService.InputChanged:Connect(function(input)
			if not dragging then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				local delta = input.Position - dragStart
				button.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + delta.X,
					startPos.Y.Scale, startPos.Y.Offset + delta.Y
				)
			end
		end)

		state.Gui = gui
		state.Button = button
		state.InputConnection = UserInputService.InputChanged
	end

	function MobileButton:Destroy(state)
		if state.InputConnection then
			pcall(function()
				state.InputConnection:Disconnect()
			end)
			state.InputConnection = nil
		end
		if state.Gui then
			pcall(function()
				state.Gui:Destroy()
			end)
			state.Gui = nil
			state.Button = nil
		end
		destroyExisting(guiParent())
	end

	return {
		Name = "MobileButton",
		Version = 1,
		Priority = 16,
		Dependencies = {"Settings"},

		Init = function(self, ctx)
			local state = {
				Alive = true,
				Gui = nil,
				Button = nil,
				InputConnection = nil,
			}

			-- A crashed previous session can leave the ScreenGui behind.
			MobileButton.Reclaim(guiParent())

			local section = ctx.Tabs.MiscSession:Section({ Side = "Right" })
			section:Header({ Text = "Interface" })
			ctx.Registry:Toggle(section, {
				Name = "Mobile UI Button",
				Default = true,
				Callback = function(value)
					state.Wanted = value == true
					if value then
						MobileButton:Create(ctx, state)
					else
						MobileButton:Destroy(state)
					end
				end,
			}, "misc.mobile_button")
			section:Label({ Text = "Drag to move, tap to toggle the hub. Works on PC and mobile and survives config reloads." })

			ctx.RegisterCleanup(function()
				MobileButton:Destroy(state)
				state.Alive = false
			end)
			return state
		end,

		Disable = function(self, ctx, state)
			MobileButton:Destroy(state)
			state.Alive = false
		end,
	}
end
