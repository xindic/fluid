local TweenService = game:GetService("TweenService")

local graph = require("../reactive/graph")
local lerp = require("./lerp")
local read = require("../utils/read")
local types = require("../reactive/types")
local values = require("./values")

local active_tweens: { TweenState<values.Animatable> } = {}

type TweenState<T> = {
	output: graph.SourceNode<T>,
	start: T,
	current: T,
	target: T,
	elapsed: number,
	info: TweenInfo,
	lerp_fn: (T, T, number) -> T,
	active: boolean,
}

local function activate<T>(state: TweenState<T>, target: T)
	state.start = state.current
	state.target = target
	state.elapsed = 0

	if not state.active then
		state.active = true
		table.insert(active_tweens, state)
	end
end

local function remove_active(index: number)
	local last = #active_tweens
	local state = active_tweens[index]
	state.active = false
	active_tweens[index] = active_tweens[last]
	active_tweens[last] = nil
end

local function tween_alpha(info: TweenInfo, elapsed: number): (number, boolean)
	if elapsed < info.DelayTime then
		return 0, false
	end

	local local_time = elapsed - info.DelayTime
	local duration = info.Time

	if duration <= 0 then
		return if info.Reverses then 0 else 1, true
	end

	local cycle_count = info.RepeatCount + 1
	local infinite = info.RepeatCount < 0

	local phases_per_cycle = if info.Reverses then 2 else 1
	local cycle_duration = duration * phases_per_cycle

	if not infinite then
		local total_duration = cycle_duration * cycle_count

		if local_time >= total_duration then
			return if info.Reverses then 0 else 1, true
		end
	end

	local phase = math.floor(local_time / duration)
	local alpha = (local_time % duration) / duration

	if info.Reverses and phase % 2 == 1 then
		alpha = 1 - alpha
	end

	return TweenService:GetValue(alpha, info.EasingStyle, info.EasingDirection), false
end

local tween = {}

function tween.create<T>(input: types.UsedAs<T>, info: types.UsedAs<TweenInfo>?): () -> read.CastIntoValue<T>
	local owner = graph.assert_stable_parent()

	local initial = read(input)
	local initial_info = read(info or TweenInfo.new(0))
	local kind = typeof(initial)
	local lerp_fn = lerp.functions[kind]

	assert(lerp_fn ~= nil, `unsupported tween datatype {kind}`)

	local output: graph.SourceNode<T> = graph.create_source_node(initial)
	local state: TweenState<T> = {
		output = output,
		start = initial,
		current = initial,
		target = initial,
		elapsed = 0,
		info = initial_info,
		lerp_fn = lerp_fn,
		active = false,
	}

	local function update_goal()
		local target = read(input)
		assert(typeof(target) == kind, "Can't switch the data types of a tween")

		if target ~= state.target then
			activate(state, target)
		end
	end

	local function update_info()
		local next_info = read(info or initial_info)

		if next_info ~= state.info then
			state.info = next_info

			if state.active then
				activate(state, state.target)
			end
		end
	end

	local goal_node = graph.create_reactive_node(owner, update_goal :: any, "deferred")
	graph.evaluate_node(goal_node)

	if info ~= nil then
		local info_node = graph.create_reactive_node(owner, update_info :: any, "deferred")
		graph.evaluate_node(info_node)
	end

	graph.push_cleanup(owner, function()
		state.active = false
	end)

	return function()
		graph.push_dependency(output)
		return output.cached_value
	end
end

function tween.step(delta_time: number)
	local index = 1

	while index <= #active_tweens do
		local state = active_tweens[index]

		if not state.active then
			remove_active(index)
			continue
		end

		state.elapsed += delta_time
		local alpha, finished = tween_alpha(state.info, state.elapsed)

		if finished then
			state.current = if state.info.Reverses then state.start else state.target
		else
			state.current = state.lerp_fn(state.start, state.target, alpha)
		end

		graph.update_node(state.output, state.current)

		if finished then
			remove_active(index)
		else
			index += 1
		end
	end
end

return tween
