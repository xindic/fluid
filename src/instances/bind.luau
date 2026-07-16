local action = require("./action")
local graph = require("../reactive/graph")
local properties = require("./properties")
local types = require("../reactive/types")

type Result = Instance | { Result } | () -> Result

type PropertyBinding =
	{
		kind: "static",
		value: any,
	}
	| {
		kind: "reactive",
		value: types.Readable<any>,
	}

type EventBinding = {
	name: string,
	callback: any,
}
type ChildBinding = Instance | (() -> Result)

type PendingBindings = {
	properties: { [string]: PropertyBinding },
	children: { ChildBinding },

	events: { EventBinding },
	actions: { action.Identity },

	parent: PropertyBinding?,
}

local function get_property(inst: Instance, property: string): any
	return (inst :: any)[property]
end

local function bind_property<T>(inst: Instance, property: string, value: types.Readable<T>)
	local property_node = graph.create_reactive_node(graph.assert_stable_parent(), function()
		inst[property] = value()
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

		table.clear(current_child_set)
		table.clear(new_child_set)

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

local function get_member(inst: Instance, name: string): any
	local success, member = pcall(get_property, inst, name)

	if not success then
		error(`Property or event {name} does not exist on {inst.ClassName}`, 3)
	end

	return member
end

local function process_props(inst: Instance, props: { [any]: any }, pending: PendingBindings)
	local nested_props: { { [any]: any } } = {}

	for key, value in props do
		local key_type = type(key)

		if key_type == "string" then
			local name = key

			if name == "Parent" then
				pending.parent = if type(value) == "function"
					then { kind = "reactive", value = value }
					else { kind = "static", value = value }
				continue
			end

			local member = get_member(inst, name)

			if typeof(member) == "RBXScriptSignal" then
				assert(type(value) == "function", `Event {name} on {inst.ClassName} requires a callback`)

				table.insert(pending.events, {
					name = name,
					callback = value,
				})
			else
				pending.properties[name] = if type(value) == "function"
					then { kind = "reactive", value = value }
					else { kind = "static", value = value }
			end

			continue
		end

		if key_type == "number" then
			if action.is_action(value) then
				table.insert(pending.actions, value)
			elseif type(value) == "table" then
				table.insert(nested_props, value)
			elseif type(value) == "function" or typeof(value) == "Instance" then
				table.insert(pending.children, value)
			end

			continue
		end

		if typeof(value) == "Instance" then
			table.insert(pending.children, value)
		end
	end

	for index = 1, #nested_props do
		process_props(inst, nested_props[index], pending)
	end
end

local function bind<T>(inst: Instance & T, props: properties.PropertiesFor<T>)
	local pending: PendingBindings = {
		properties = {},
		children = {},

		events = {},
		actions = {},

		parent = nil,
	}

	process_props(inst, props, pending)

	for name, binding in pending.properties do
		if binding.kind == "reactive" then
			bind_property(inst, name, binding.value)
		else
			inst[name] = binding.value
		end
	end

	for index = 1, #pending.children do
		local child = pending.children[index]

		if typeof(child) == "Instance" then
			child.Parent = inst
		else
			bind_reactive_child(inst, child :: () -> Result)
		end
	end

	local parent = pending.parent
	if parent ~= nil then
		if parent.kind == "reactive" then
			bind_property(inst, "Parent", parent.value)
		else
			inst.Parent = parent.value
		end
	end

	for index = 1, #pending.events do
		local event = pending.events[index]
		bind_event(inst, event.name, event.callback)
	end

	for index = 1, #pending.actions do
		pending.actions[index].callback(inst)
	end

	return inst
end

return bind
