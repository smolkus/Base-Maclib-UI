return function(Import)
	local UiSchema = {}
	UiSchema.__index = UiSchema

	function UiSchema.new(registry)
		local self = setmetatable({
			Registry = registry,
			Tabs = {},
			Sections = setmetatable({}, {__mode = "k"}),
		}, UiSchema)
		registry.Schema = self
		return self
	end

	function UiSchema:_TrackSection(section, holder, settings)
		local record = {
			Title = nil,
			Side = type(settings) == "table" and settings.Side or nil,
			Flags = {},
		}
		table.insert(holder.Sections, record)
		self.Sections[section] = record
		local header = section.Header
		if type(header) == "function" then
			section.Header = function(target, headerSettings, ...)
				if record.Title == nil and type(headerSettings) == "table" then
					record.Title = headerSettings.Text or headerSettings.Title
				end
				return header(target, headerSettings, ...)
			end
		end
		return section
	end

	function UiSchema:_WrapSections(target, holder)
		local createSection = target.Section
		if type(createSection) ~= "function" then return end
		target.Section = function(owner, settings, ...)
			local section = createSection(owner, settings, ...)
			return self:_TrackSection(section, holder, settings)
		end
	end

	function UiSchema:TrackTab(tab, name)
		local record = {Name = tostring(name or "Tab"), Direct = {Name = nil, Sections = {}}, Subtabs = {}}
		table.insert(self.Tabs, record)
		self:_WrapSections(tab, record.Direct)
		local createGroup = tab.SubTabGroup
		if type(createGroup) == "function" then
			tab.SubTabGroup = function(owner, ...)
				local group = createGroup(owner, ...)
				local createSubtab = group.SubTab
				group.SubTab = function(groupOwner, settings, ...)
					local subtab = createSubtab(groupOwner, settings, ...)
					local subRecord = {Name = type(settings) == "table" and settings.Name or nil, Sections = {}}
					table.insert(record.Subtabs, subRecord)
					self:_WrapSections(subtab, subRecord)
					return subtab
				end
				return group
			end
		end
		return tab
	end

	function UiSchema:TrackGroup(group)
		local createTab = group.Tab
		group.Tab = function(owner, settings, ...)
			local tab = createTab(owner, settings, ...)
			return self:TrackTab(tab, type(settings) == "table" and settings.Name or nil)
		end
		return group
	end

	function UiSchema:AddControl(section, flag)
		local record = self.Sections[section]
		if record then table.insert(record.Flags, flag) end
	end

	local function control(entry)
		local meta = entry.Meta or {}
		local output = {
			flag = entry.Flag,
			kind = entry.Kind,
			title = meta.Title and tostring(meta.Title) or entry.Flag,
		}
		if type(entry.Default) ~= "userdata" then output.default = entry.Default end
		if meta.Minimum then output.min = meta.Minimum end
		if meta.Maximum then output.max = meta.Maximum end
		if meta.Step then output.step = meta.Step end
		if meta.Options then output.options = meta.Options end
		if meta.Multi then output.multi = true end
		return output
	end

	function UiSchema:_Sections(list)
		local output = {}
		for _, section in ipairs(list) do
			local controls = {}
			for _, flag in ipairs(section.Flags) do
				local entry = self.Registry.Entries[flag]
				if entry then table.insert(controls, control(entry)) end
			end
			if #controls > 0 then
				table.insert(output, {title = section.Title, side = section.Side, controls = controls})
			end
		end
		return output
	end

	function UiSchema:Build(placeId)
		local tabs = {}
		for _, tab in ipairs(self.Tabs) do
			local subtabs = {}
			local direct = self:_Sections(tab.Direct.Sections)
			if #direct > 0 then table.insert(subtabs, {name = nil, sections = direct}) end
			for _, subtab in ipairs(tab.Subtabs) do
				local sections = self:_Sections(subtab.Sections)
				if #sections > 0 then table.insert(subtabs, {name = subtab.Name, sections = sections}) end
			end
			if #subtabs > 0 then table.insert(tabs, {name = tab.Name, subtabs = subtabs}) end
		end
		return {version = 1, placeId = tostring(placeId), tabs = tabs}
	end

	return UiSchema
end
