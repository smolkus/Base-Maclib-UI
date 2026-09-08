return function(Import)
	local MobileButton = {}
local CoreGui = game:GetService("CoreGui")

local function guiParent()
	if type(gethui) == "function" then
		local ok, value = pcall(gethui)
		if ok then
			return value
		end
	end
	return CoreGui
end

	return {
		Name = "MobileButton",
		Version = 2,
		Priority = 16,
		Dependencies = {"Settings"},

		Init = function(self, ctx)
			local state = { Alive = true, Mounted = false }

			-- A crashed previous session can leave the ScreenGui behind; the
			-- bootstrap already reclaims it, this only guards re-registration.
			ctx.UIManager:UnmountMobileLauncher()

			local section = ctx.Tabs.MiscSession:Section({ Side = "Right" })
			section:Header({ Text = "Interface" })
			ctx.Registry:Toggle(section, {
				Name = "Mobile UI Button",
				Default = true,
				Callback = function(value)
					state.Wanted = value == true
					if value then
						ctx.UIManager:MountMobileLauncher(guiParent(), ctx.Config)
					else
						ctx.UIManager:UnmountMobileLauncher()
					end
				end,
			}, "misc.mobile_button")
			section:Label({ Text = "Drag to move, tap to toggle the hub. Shown on PC and mobile; the badge reflects whether the hub is open." })

			ctx.RegisterCleanup(function()
				ctx.UIManager:UnmountMobileLauncher()
				state.Alive = false
			end)
			return state
		end,

		Disable = function(self, ctx, state)
			ctx.UIManager:UnmountMobileLauncher()
			state.Alive = false
		end,
	}
end
