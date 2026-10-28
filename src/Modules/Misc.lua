return function(Import)
	local Players = game:GetService("Players")
	local TeleportService = game:GetService("TeleportService")
	local Misc = {}

	return {
		Name = "Misc",
		Version = 1,
		Priority = 15,
		Dependencies = {"Settings"},

		Init = function(self, ctx)
			local state = { Alive = true }

			local session = ctx.Tabs.MiscSession:Section({ Side = "Left" })
			session:Header({ Text = "Session" })
			ctx.Registry:Toggle(session, {
				Name = "Auto Execute",
				Default = ctx.Config.Account.Session.AutoExecute == true,
				Callback = function(value)
					ctx.Session:SetAutoExecute(value == true)
				end,
			}, "misc.auto_execute")
			ctx.Registry:Toggle(session, {
				Name = "Auto Reconnect",
				Default = ctx.Config.Account.Session.AutoReconnect == true,
				Callback = function(value)
					ctx.Session:SetAutoReconnect(value == true)
					ctx.Config.Account.Session.AutoReconnect = value == true
					ctx.Config.AccountDirty = true
				end,
			}, "misc.auto_reconnect")
			ctx.Registry:Action(session, {
				Name = "Rejoin Server",
				Callback = function()
					TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, Players.LocalPlayer)
				end,
			}, "misc.rejoin")
			session:Label({ Text = "Auto Execute relaunches the hub after teleports and rejoins. Auto Reconnect recovers dropped sessions with backoff." })
			return state
		end,

		Disable = function(self, ctx, state)
			state.Alive = false
		end,
	}
end
