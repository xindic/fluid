local action = require("./action")
local graph = require("../reactive/graph")
local properties = require("./properties")
local scheduler = require("../scheduler")
local types = require("../reactive/types")

local function set_property(inst: Instance, property: string, value: any)
	(inst :: any)[property] = value
end

local function get_property(inst: Instance, property: string): any
	return (inst :: any)[property]
end

local function bind_property<T>(inst: Instance, property: string, value: types.Readable<T>)
	local property_node = graph.create_reactive_node(graph.assert_stable_parent(), function()
		set_property(inst, property, value())
		return nil
	end, "eager", nil)

	graph.evaluate_node(property_node)
end

local function bind_event(inst: Instance, event_name: string, func: <T...>(T...) -> ())
	local event = (inst :: any)[event_name] :: RBXScriptSignal
	local connection = event:Connect(func)

	graph.push_cleanup(graph.assert_scope(), function()
		connection:Disconnect()
	end)
end

type Result = Instance | { Result } | () -> Result

local function reactive_child_effect(
	inst: Instance,
	func: () -> Result,
	sets: {
		new: { [Instance]: true },
		current: { [Instance]: true },
	}
)
	local new_child_set = sets.new
	local current_child_set = sets.current
	local source_result = func()

	if not source_result then
		for old_inst in current_child_set do
			old_inst.Parent = nil
		end

		return sets
	end

	local function process_child(child: Result)
		if typeof(child) == "Instance" then
			new_child_set[child] = true

			if current_child_set[child] then
				current_child_set[child] = nil
				return
			end

			child.Parent = inst
			return
		end

		if typeof(child) == "function" then
			local children: { new: { [Instance]: true }, current: { [Instance]: true } } = { new = {}, current = {} }

			graph.create_reactive_node(graph.get_scope(), function(value)
				return reactive_child_effect(inst, child, value)
			end, "deferred", children)

			graph.push_cleanup(graph.get_scope(), function()
				for child in children.current do
					child.Parent = nil
				end
			end)

			return
		end

		for _, child in child do
			process_child(child)
		end

		return
	end

	process_child(source_result)

	for child in current_child_set do
		child.Parent = nil
	end

	table.clear(current_child_set)
	sets.current, sets.new = new_child_set, current_child_set

	return sets
end

local function bind_reactive_child(inst: Instance, func: () -> Result)
	local stable_node = graph.get_scope() :: graph.StableNode<unknown>

	local children: { new: { [Instance]: true }, current: { [Instance]: true } } = { new = {}, current = {} }

	local property_node = graph.create_reactive_node(stable_node :: any, function(value)
		return reactive_child_effect(inst, func, value)
	end, "deferred", children)

	graph.evaluate_node(property_node)
end

type PendingBindings = {
	property_names: { string },
	property_values: { any },
	children: { Instance },
}

type ParentBinding = {
	present: boolean,
	value: any,
}

local function get_member(inst: Instance, name: string): any
	local success, member = pcall(get_property, inst, name)

	if not success then
		error(`Property or event {name} does not exist on {inst.ClassName}`, 3)
	end

	return member
end

local function process_props(
	inst: Instance,
	props: { [unknown & number]: unknown },
	pending: PendingBindings,
	parent: ParentBinding
)
	for key, value in props do
		local key_type = type(key)

		if key_type == "number" then
			if action.is_action(value) then
				(value :: action.Identity).callback(inst)
			elseif type(value) == "table" then
				process_props(inst, value :: any, pending, parent)
			elseif type(value) == "function" then
				bind_reactive_child(inst, value :: any)
			elseif typeof(value) == "Instance" then
				pending.children[#pending.children + 1] = value :: Instance
			end

			continue
		end

		if key_type == "string" then
			local property_name = key :: string

			if property_name == "Parent" then
				parent.present = true
				parent.value = value
				continue
			end

			local member = get_member(inst, property_name)

			if typeof(member) == "RBXScriptSignal" then
				assert(type(value) == "function", `Event {property_name} on {inst.ClassName} requires a callback`)

				bind_event(inst, property_name, value :: any)
			elseif type(value) == "function" then
				bind_property(inst, property_name, value :: any)
			else
				local index = #pending.property_names + 1
				pending.property_names[index] = property_name
				pending.property_values[index] = value
			end

			continue
		end

		if typeof(value) == "Instance" then
			pending.children[#pending.children + 1] = value :: Instance
		end
	end
end

local function bind<T>(inst: Instance & T, props: properties.PropertiesFor<T>)
	local pending: PendingBindings = {
		property_names = {},
		property_values = {},
		children = {},
	}

	local parent: ParentBinding = {
		present = false,
		value = nil,
	}

	process_props(inst, props :: any, pending, parent)

	local property_count = #pending.property_names

	local child_count = #pending.children

	if property_count > 0 or child_count > 0 or (parent.present and type(parent.value) ~= "function") then
		scheduler.defer(function()
			for index = 1, property_count do
				set_property(inst, pending.property_names[index], pending.property_values[index])
			end

			for index = 1, child_count do
				pending.children[index].Parent = inst
			end

			if parent.present and type(parent.value) ~= "function" then
				set_property(inst, "Parent", parent.value)
			end
		end)
	end

	if parent.present and type(parent.value) == "function" then
		bind_property(inst, "Parent", parent.value)
	end

	return inst
end

return bind
