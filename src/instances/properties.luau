local action = require("./action")

type instance = Instance
type Action = action.Identity
type Signal = RBXScriptSignal
type UnknownSignalCallback = (...any) -> ()

type function get_connect(v: type): type?
	local connect = v:readproperty(types.singleton("Connect"))

	if connect and connect:is("function") then
		local head = connect:parameters().head

		if not head then
			return nil
		end
		local callback = head[2]

		if callback and callback:is("function") then
			return callback
		end
	end

	return nil
end

type function is_signal(v: type): type?
	if v == Signal and v.tag == "extern" then
		return UnknownSignalCallback
	-- luau lsp types RBXScriptSignals as tables
	elseif v.tag == "table" then
		local connect = get_connect(v)

		if connect then
			return connect
		end

		-- i cba to test if this is needed or not
		local metatable = v:metatable()

		if metatable then
			connect = get_connect(metatable)

			if connect then
				return connect
			end
		end
	end

	return nil
end

export type function PropertiesFor(class: type): type
	local read_only_properties = {
		RobloxLocked = true,
		ClassName = true,
		UniqueId = true,
	}

	local function inherits(child: type, parent: type): boolean
		if not child:is("extern") or not parent:is("extern") then
			return false
		end

		local current: type? = child
		while current do
			if current == parent then
				return true
			end

			current = current:readparent()
		end

		return false
	end

	local function make_property_type(property: { read: type?, write: type? }): type?
		local read_type = property.read
		if read_type == nil then
			return nil
		end

		local callback = is_signal(read_type)
		if callback then
			return types.optional(callback)
		end

		if read_type:is("function") or read_type:is("intersection") then
			return nil
		end

		local write_type = property.write
		if write_type == nil then
			return nil
		end

		local getter = types.newfunction({ head = {} }, { head = { read_type } })

		return types.optional(types.unionof(getter, write_type))
	end

	local function collect_extern(value: type): { [string]: { key: type, value: type } }?
		if not inherits(value, instance) then
			return nil
		end

		local result = {}
		local current: type? = value

		while current do
			for property_key, property in current:properties() do
				if not property_key:is("singleton") then
					continue
				end

				local property_name = property_key:value()
				if type(property_name) ~= "string" then
					continue
				end

				if read_only_properties[property_name] then
					continue
				end

				if result[property_name] ~= nil then
					continue
				end

				local property_type = make_property_type(property)

				if property_type then
					result[property_name] = {
						key = property_key,
						value = property_type,
					}
				end
			end

			current = current:readparent()
		end

		return result
	end

	local function combine(left: type, right: type): type
		if left == right then
			return left
		end

		return types.intersectionof(left, right)
	end

	local function clone_properties(source: { [string]: { key: type, value: type } })
		local result = {}

		for name, property in source do
			result[name] = property
		end

		return result
	end

	local function resolve(value: type)
		if value:is("extern") then
			return collect_extern(value)
		end

		if value:is("intersection") then
			local result = {}
			local found_instance_component = false

			for _, component in value:components() do
				local tag = component.tag

				if tag == "unknown" or tag == "any" or tag == "generic" or tag == "table" then
					continue
				end

				local component_properties = resolve(component)
				if component_properties == nil then
					return nil
				end

				found_instance_component = true

				for name, property in component_properties do
					local existing = result[name]

					if existing then
						result[name] = {
							key = existing.key,
							value = combine(existing.value, property.value),
						}
					else
						result[name] = property
					end
				end
			end

			if not found_instance_component then
				return nil
			end

			return result
		end

		if value:is("union") then
			local result = nil
			local found_component = false

			for _, component in value:components() do
				if component:is("never") then
					continue
				end

				local component_properties = resolve(component)

				if component_properties == nil then
					return nil
				end

				found_component = true
				if result == nil then
					result = clone_properties(component_properties)
					continue
				end

				for name, existing in result do
					local property = component_properties[name]

					if property == nil then
						result[name] = nil
					else
						result[name] = {
							key = existing.key,
							value = combine(existing.value, property.value),
						}
					end
				end
			end

			if not found_component then
				return nil
			end

			return result
		end

		return nil
	end

	local resolved = resolve(class)
	if resolved == nil then
		error(`Expected an Instance type or a compatible Instance union/intersection, got '{class.tag}'`)
	end

	local properties = types.newtable()
	for _, property in resolved do
		properties:setproperty(property.key, property.value)
	end

	local function_returns_child = types.newfunction()
	local child_only_union = types.unionof(function_returns_child, instance)

	local nested_children = types.newtable()
	local nested_child_union = types.unionof(child_only_union, nested_children)

	nested_children:setindexer(types.number, nested_child_union)

	function_returns_child:setreturns({ nested_child_union })

	local full_union = types.unionof(child_only_union, Action, properties)

	properties:setindexer(types.number, types.optional(full_union))

	return properties
end

return nil
