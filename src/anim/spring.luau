--[[
	Temporarily named this until Luau language server fixes issue.
]]
local coefficients = require("./spring_coefficients")
local graph = require("../reactive/graph")
local read = require("../utils/read")
local types = require("../reactive/types")
local values = require("./values")

local SLEEP_VELOCITY = 1e-3
local SLEEP_DISTANCE = 1e-5

type SpringState = {
	position: values.PackedValue,
	velocity: values.PackedValue,
	target: values.PackedValue,

	datatype: string,
	value_type: values.ValueType<any>,
	elements: number,

	damping: number,
	speed: number,

	unpacked_value: values.Animatable,
}

type SpringControls<T> = {
	position: T?,
	impulse: T?,
	velocity: T?,
}

-- Internally heterogeneous, so the output node type is erased here.
local active_springs: { [SpringState]: graph.SourceNode<any> } = {}

local function packed_values_differ(left: values.PackedValue, right: values.PackedValue, count: number): boolean
	for index = 1, count do
		if left[index] ~= right[index] then
			return true
		end
	end

	return false
end

local function step_spring(state: SpringState, delta_time: number)
	local pos_pos, pos_vel, vel_pos, vel_vel = coefficients(delta_time, state.damping, state.speed)

	local max_velocity = 0
	local distance_squared = 0

	for index = 1, state.elements do
		local target = state.target[index]
		local delta = state.position[index] - target
		local velocity = state.velocity[index]

		local next_delta = delta * pos_pos + velocity * pos_vel
		local next_velocity = delta * vel_pos + velocity * vel_vel

		-- Protect against unstable user-provided spring parameters.
		if next_delta ~= next_delta or next_velocity ~= next_velocity then
			next_delta = 0
			next_velocity = 0
		end

		state.position[index] = target + next_delta
		state.velocity[index] = next_velocity
		max_velocity = math.max(max_velocity, math.abs(next_velocity))
		distance_squared += next_delta * next_delta
	end

	local sleeping = max_velocity <= SLEEP_VELOCITY and distance_squared <= SLEEP_DISTANCE

	if sleeping then
		for index = 1, state.elements do
			state.position[index] = state.target[index]
			state.velocity[index] = 0
		end

		active_springs[state] = nil
	end

	state.unpacked_value = state.value_type.unpack(state.position)
end

local spring = {}

function spring.create<T>(
	input: types.UsedAs<T>,
	speed: number,
	damping: number
): (() -> read.CastIntoValue<T>, (SpringControls<T>) -> ())
	local owner = graph.assert_stable_parent()

	local initial = read(input)
	local output: graph.SourceNode<T> = graph.create_source_node(initial)
	local starting_datatype, starting_position, value_type = values.pack(initial :: any)

	local spring_state: SpringState = {
		position = table.clone(starting_position),
		velocity = table.create(value_type.count, 0),
		target = starting_position,

		elements = value_type.count,
		datatype = starting_datatype,
		value_type = value_type,

		speed = speed,
		damping = damping,

		unpacked_value = initial :: any,
	}

	local function pack_checked(value: any): values.PackedValue
		local datatype, packed = values.pack(value)
		assert(datatype == spring_state.datatype, "Can't switch the data types of a spring")

		return packed
	end

	local function on_update()
		local next_target = pack_checked(read(input))

		-- The first reactive evaluation sees the initial target.
		-- Do not activate a spring that has nowhere to move.
		if packed_values_differ(spring_state.target, next_target, spring_state.elements) then
			spring_state.target = next_target
			active_springs[spring_state] = output
		end

		return nil
	end

	local input_node = graph.create_reactive_node(owner, on_update, "deferred")

	graph.evaluate_node(input_node)
	graph.push_cleanup(owner, function()
		active_springs[spring_state] = nil
	end)

	local function read_output()
		graph.push_dependency(output)
		return output.cached_value
	end

	local function control(controls: SpringControls<T>)
		-- Refresh the current reactive target first.
		on_update()

		local should_activate = false
		if controls.position ~= nil then
			spring_state.position = pack_checked(controls.position)
			should_activate = true
		end

		if controls.velocity ~= nil then
			spring_state.velocity = pack_checked(controls.velocity)
			should_activate = true
		end

		if controls.impulse ~= nil then
			local impulse = pack_checked(controls.impulse)

			for index = 1, spring_state.elements do
				spring_state.velocity[index] += impulse[index]
			end

			should_activate = true
		end

		if should_activate then
			active_springs[spring_state] = output
		end
	end

	return read_output, control
end

function spring.step(delta_time: number)
	for spring_state, output in active_springs do
		step_spring(spring_state, delta_time)
		graph.update_node(output, spring_state.unpacked_value)
	end
end

return spring
