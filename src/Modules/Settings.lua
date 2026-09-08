return function()
	return {
		Name = "Settings",
		Version = 5,
		Priority = 20,
		Dependencies = {},

		Init = function(self, ctx)
			local function isActive()
				local state = ctx.Runtime.Modules and ctx.Runtime.Modules.States.Settings
				return state == "Loading" or state == "Running"
			end
			local configs = ctx.Tabs.Settings:Section({ Side = "Left" })
			local createConfig = ctx.Tabs.Settings:Section({ Side = "Left" })
			local actions = ctx.Tabs.Settings:Section({ Side = "Left" })
			local behavior = ctx.Tabs.Settings:Section({ Side = "Left" })
			local runtimeSection = ctx.Tabs.Settings:Section({ Side = "Right" })
			local appearance = ctx.Tabs.Settings:Section({ Side = "Right" })

			configs:Header({ Text = "Configs" })
			local names = ctx.Config:List()
			local selected = ctx.Config.Account.SelectedConfig
			local configDropdown = configs:Dropdown({
				Name = "Configs",
				Search = true,
				Multi = false,
				Required = true,
				Options = names,
				Default = table.find(names, selected) or 1,
				Callback = function(value)
					if not isActive() then
						return
					end
					if value then
						local ok, err = ctx.Config:SetSelected(value)
						if not ok then
							ctx.Runtime:Notify("Select config failed", tostring(err))
						end
					end
				end,
			})

			createConfig:Header({ Text = "Create Config" })
			local pendingName = ""
			local nameInput = createConfig:Input({
				Name = "Config Name",
				Placeholder = "Create config",
				AcceptedCharacters = "All",
				Default = "",
				onChanged = function(value)
					if isActive() then
						pendingName = value
					end
				end,
				Callback = function(value)
					if isActive() then
						pendingName = value
					end
				end,
			})

			local function notifyResult(action, ok, message)
				ctx.Runtime:Notify(
					ok and action or (action .. " failed"),
					message or (ok and "Done." or "Unknown error")
				)
			end

			local function clearName()
				nameInput:UpdateText("")
				pendingName = ""
			end

			local function refresh(selection)
				local updated = ctx.Config:List()
				local wanted = selection or ctx.Config.Account.SelectedConfig or updated[1]
				configDropdown:ClearOptions()
				configDropdown:InsertOptions(updated)
				if wanted then
					configDropdown:UpdateSelection(wanted)
				end
			end

			createConfig:Button({
				Name = "Create",
				Callback = function()
					if not isActive() then
						return
					end
					local clean = ctx.Config:SanitizeName(pendingName)
					local ok, err = ctx.Config:Create(clean)
					if ok then
						ctx.Config:ActivateProfile()
						refresh(clean)
						clearName()
					end
					notifyResult("Create config", ok, ok and ("Created global config " .. clean) or err)
				end,
			})
			actions:Header({ Text = "Config Actions" })
			actions:Button({
				Name = "Delete",
				Callback = function()
					if not isActive() then
						return
					end
					local target = ctx.Config.Account.SelectedConfig
					ctx.Window:Dialog({
						Title = "Delete config",
						Description = "Delete global config '" .. tostring(target) .. "'?",
						Buttons = {
							{
								Name = "Delete",
								Callback = function()
									if not isActive() then
										return
									end
									local ok, err = ctx.Config:Delete(target)
									if ok then
										refresh(ctx.Config.Account.SelectedConfig)
										local loadOk, loadError = ctx.Config:Load(ctx.Config.Account.SelectedConfig)
										if not loadOk then
											ctx.Runtime:Notify("Replacement config failed", tostring(loadError))
										else
											ctx.Config:ActivateProfile()
										end
									end
									notifyResult("Delete config", ok, ok and ("Deleted " .. target) or err)
								end,
							},
							{ Name = "Cancel" },
						},
					})
				end,
			})
			actions:Button({
				Name = "Load",
				Callback = function()
					if not isActive() then
						return
					end
					local target = ctx.Config.Account.SelectedConfig
					local ok, err = ctx.Config:Load(target)
					if ok then ctx.Config:ActivateProfile() end
					notifyResult(
						"Load config",
						ok,
						ok and ("Loaded revision " .. tostring(err.Revision) .. " of " .. target) or err
					)
				end,
			})
			actions:Button({
				Name = "Save",
				Callback = function()
					if not isActive() then
						return
					end
					if not ctx.Config.ProfileReady then
						notifyResult(
							"Save config",
							false,
							"Load or create a config before saving so stored settings are not overwritten."
						)
						return
					end
					ctx.Config.ConfigDirty = true
					local ok, err = ctx.Config:Flush()
					notifyResult("Save config", ok, ok and ("Saved " .. ctx.Config.Account.SelectedConfig) or err)
				end,
			})
			behavior:Header({ Text = "Config Behavior" })
			behavior:Toggle({
				Name = "Auto Load Selected",
				Default = ctx.Config.Account.AutoLoadSelected == true,
				Callback = function(value)
					if not isActive() then
						return
					end
					local ok, err = ctx.Config:UpdateAccount(function(account)
						account.AutoLoadSelected = value == true
					end, true)
					if not ok then
						ctx.Runtime:Notify("Auto Load failed", tostring(err))
					end
				end,
			})
			behavior:Toggle({
				Name = "Auto Save Settings",
				Default = ctx.Config.Account.AutoSave == true,
				Callback = function(value)
					if not isActive() then
						return
					end
					ctx.Config.Account.AutoSave = value == true
					ctx.Config.AccountDirty = true
					local ok, err
					if value then
						ok, err = ctx.Config:Flush()
					else
						ok, err = ctx.Config:SaveAccount(true)
					end
					if not ok then
						ctx.Runtime:Notify("Auto Save failed", tostring(err))
					end
				end,
			})

			runtimeSection:Header({ Text = "Runtime" })
			runtimeSection:Button({
				Name = "Unload",
				Callback = function()
					if not isActive() or ctx.Runtime.ShuttingDown then
						return
					end
					task.defer(function()
						ctx.Runtime:Shutdown("manual unload")
					end)
				end,
			})
			appearance:Header({ Text = "Appearance" })
			appearance:Toggle({
				Name = "Hide UI on Load",
				Default = ctx.Config.Account.UI.HiddenOnLoad == true,
				Callback = function(value)
					if not isActive() then
						return
					end
					ctx.Config:UpdateAccount(function(account)
						account.UI.HiddenOnLoad = value == true
					end, false)
				end,
			})
			local keyName = tostring(ctx.Config.Account.UI.ToggleKey or "RightShift")
			local defaultKey = Enum.KeyCode[keyName] or Enum.KeyCode.RightShift
			appearance:Keybind({
				Name = "UI Hide / Show Key",
				Default = defaultKey,
				Blacklist = { Enum.KeyCode.Unknown },
				Callback = function() end,
				onBinded = function(bind)
					if not isActive() then
						return
					end
					if not bind then
						return
					end
					ctx.Window:SetKeybind(bind)
					ctx.Config:UpdateAccount(function(account)
						account.UI.ToggleKey = bind.Name
					end, false)
				end,
			})

			local defaultPercent = math.floor(ctx.UIManager:GetRequestedScale() * 100 + 0.5)
			appearance:Slider({
				Name = "UI Size",
				Default = defaultPercent,
				Minimum = 35,
				Maximum = 120,
				DisplayMethod = "LiteralPercent",
				Precision = 0,
				Step = 1,
				Callback = function(value)
					if not isActive() then
						return
					end
					local requested = math.clamp(value / 100, 0.35, 1.2)
					ctx.UIManager:SetRequestedScale(requested, false)
					ctx.Config:UpdateAccount(function(account)
						account.UI.Scale[ctx.UIManager.Device] = requested
					end, false)
				end,
				onInputComplete = function(value)
					if not isActive() then
						return
					end
					ctx.UIManager:SetRequestedScale(
						math.clamp((tonumber(value) or defaultPercent) / 100, 0.35, 1.2),
						false
					)
				end,
			})

			return { Refresh = refresh }
		end,
	}
end
