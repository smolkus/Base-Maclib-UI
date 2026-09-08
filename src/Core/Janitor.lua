return function(Import)
	local Util = Import("Util")
	local Janitor = {}
	Janitor.__index = Janitor

	function Janitor.new()
		return setmetatable({Items = {}, Cleaning = false}, Janitor)
	end

	function Janitor:Add(item, method)
		if item == nil then return item end
		table.insert(self.Items, {Item = item, Method = method})
		return item
	end

	function Janitor:AddConnection(connection)
		return self:Add(connection, "Disconnect")
	end

	function Janitor:AddInstance(instance)
		return self:Add(instance, "Destroy")
	end

	function Janitor:Cleanup()
		if self.Cleaning then return end
		self.Cleaning = true
		for index = #self.Items, 1, -1 do
			local entry = self.Items[index]
			local item, method = entry.Item, entry.Method
			if type(item) == "function" and method == nil then
				Util.SafeCall("cleanup callback", item)
			elseif item ~= nil then
				if type(method) == "function" then
					Util.SafeCall("cleanup method", method, item)
				elseif type(method) == "string" and type(item[method]) == "function" then
					Util.SafeCall("cleanup " .. method, item[method], item)
				elseif typeof(item) == "thread" and type(task.cancel) == "function" then
					local statusOk, status = pcall(coroutine.status, item)
					if not statusOk or status ~= "dead" then Util.SafeCall("cancel task", task.cancel, item) end
				elseif typeof(item) == "RBXScriptConnection" then
					Util.SafeCall("disconnect", item.Disconnect, item)
				elseif typeof(item) == "Instance" then
					Util.SafeCall("destroy", item.Destroy, item)
				end
			end
			self.Items[index] = nil
		end
	end

	return Janitor
end
