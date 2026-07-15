local graph = require("@src/reactive/graph")
local testkit = require("@vendor/testkit")
local BENCH, START = testkit.benchmark()

local fluid = require("../src")
local source = fluid.source
local derive = fluid.derive
local effect = fluid.effect
local indexes = fluid.for_keys
local values = fluid.for_values
local cleanup = fluid.cleanup

math.randomseed(123456)

local function TITLE(name: string)
	print()
	print(testkit.color.white(name))
end

local function ROOT_BENCH(name: string, fn: () -> ())
	fluid.root(function(destroy)
		BENCH(name, fn)
		return destroy
	end)()
end

local N = 2 ^ 18
local GRAPH_N = 2 ^ 14
local GRAPH_SIZE = 256
local DEEP_GRAPH_SIZE = 64
local EAGER_FAN_IN = 128
local EAGER_SWEEPS = 4

TITLE("sources")

BENCH("create source", function()
	local cache = table.create(N)

	for i = 1, START(N) do
		cache[i] = source(1)
	end
end)

BENCH("get value", function()
	local src = source(1)

	for _ = 1, START(N) do
		src()
	end
end)

BENCH("set value", function()
	local src = source(1)

	for i = 1, START(N) do
		src(i)
	end
end)

ROOT_BENCH("derive 1 source", function()
	local cache = table.create(N)
	local src = source(1)

	for i = 1, START(N) do
		cache[i] = derive(function()
			return src()
		end)
	end
end)

ROOT_BENCH("derive 4 sources", function()
	local cache = table.create(N)

	local src1 = source(1)
	local src2 = source(2)
	local src3 = source(3)
	local src4 = source(4)

	for i = 1, START(N) do
		cache[i] = derive(function()
			return src1() + src2() + src3() + src4()
		end)
	end
end)

TITLE("graphs")

ROOT_BENCH("update populated 1->1 graph", function()
	local src = source(0)

	local derived = derive(function()
		return src()
	end)

	-- Establish the dependency before measuring updates.
	derived()

	print("START")
	for i = 1, START(GRAPH_N) do
		src(i)
		derived()
	end
	print("END")
end)

ROOT_BENCH("update populated 1->1 graph with cleanup", function()
	local src = source(0)

	local derived = derive(function()
		cleanup(function() end)
		return src()
	end)

	derived()

	for i = 1, START(GRAPH_N) do
		src(i)
		derived()
	end
end)

ROOT_BENCH(`update populated 1->{GRAPH_SIZE} graph`, function()
	local src = source(0)
	local derived_nodes = table.create(GRAPH_SIZE)

	for index = 1, GRAPH_SIZE do
		derived_nodes[index] = derive(function()
			return src()
		end)
	end

	-- Establish all source -> derive edges.
	for index = 1, GRAPH_SIZE do
		derived_nodes[index]()
	end

	for iteration = 1, START(10) do
		src(iteration)

		-- Fully update the lazy graph.
		for index = 1, GRAPH_SIZE do
			derived_nodes[index]()
		end
	end
end)

ROOT_BENCH(`update populated {DEEP_GRAPH_SIZE}-deep graph`, function()
	local src = source(0)
	local last = src

	for _ = 1, DEEP_GRAPH_SIZE do
		local previous = last

		last = derive(function()
			return previous()
		end)
	end

	last()

	for iteration = 1, START(10) do
		src(iteration)
		last()
	end
end)

ROOT_BENCH(`update populated {GRAPH_SIZE}->1 graph`, function()
	local srcs = table.create(GRAPH_SIZE)

	for index = 1, GRAPH_SIZE do
		srcs[index] = source(0)
	end

	local combined = derive(function()
		for index = 1, GRAPH_SIZE do
			srcs[index]()
		end

		return false
	end)

	-- Establish all parent dependencies.
	combined()

	for index = 1, START(GRAPH_SIZE) do
		srcs[index](index)
		combined()
	end
end)

ROOT_BENCH(`update all parents of populated {GRAPH_SIZE}->1 graph`, function()
	local srcs = table.create(GRAPH_SIZE)

	for index = 1, GRAPH_SIZE do
		srcs[index] = source(0)
	end

	local combined = derive(function()
		for index = 1, GRAPH_SIZE do
			srcs[index]()
		end

		return false
	end)

	combined()

	for iteration = 1, START(1) do
		for index = 1, GRAPH_SIZE do
			srcs[index](iteration)
		end

		-- Reconcile the dirty lazy node once after all writes.
		combined()
	end
end)

ROOT_BENCH(`update all parents of {EAGER_FAN_IN}->1 eager graph`, function()
	local srcs = table.create(EAGER_FAN_IN)

	for index = 1, EAGER_FAN_IN do
		srcs[index] = source(0)
	end

	local observed = 0

	effect(function()
		local total = 0

		for index = 1, EAGER_FAN_IN do
			total += srcs[index]()
		end

		observed = total
	end)

	local sweeps = START(EAGER_SWEEPS)

	for sweep = 1, sweeps do
		for index = 1, EAGER_FAN_IN do
			srcs[index](sweep)
		end
	end

	assert(observed == EAGER_FAN_IN * sweeps)
end)

local batch = graph.batch

if batch ~= nil then
	ROOT_BENCH(`update all parents of {EAGER_FAN_IN}->1 eager graph (batched)`, function()
		local srcs = table.create(EAGER_FAN_IN)

		for index = 1, EAGER_FAN_IN do
			srcs[index] = source(0)
		end

		local observed = 0

		effect(function()
			local total = 0

			for index = 1, EAGER_FAN_IN do
				total += srcs[index]()
			end

			observed = total
		end)

		local sweeps = START(EAGER_SWEEPS)

		for sweep = 1, sweeps do
			batch(function()
				for index = 1, EAGER_FAN_IN do
					srcs[index](sweep)
				end
			end)
		end

		assert(observed == EAGER_FAN_IN * sweeps)
	end)
end

ROOT_BENCH(`update {GRAPH_SIZE} 1->1 common external graph`, function()
	local external = source(0)

	local srcs = table.create(GRAPH_SIZE)
	local derived_nodes = table.create(GRAPH_SIZE)

	for index = 1, GRAPH_SIZE do
		srcs[index] = source(0)

		local src = srcs[index]

		derived_nodes[index] = derive(function()
			return src() + external()
		end)
	end

	-- Establish all dependencies.
	for index = 1, GRAPH_SIZE do
		derived_nodes[index]()
	end

	for iteration = 1, START(10) do
		for index = 1, GRAPH_SIZE do
			srcs[index](iteration)
			derived_nodes[index]()
		end
	end
end)

if Instance ~= nil then
	TITLE("property apply")

	ROOT_BENCH("apply 0 properties", function()
		local apply = require("../src/instances/bind")
		local instance = fluid.create("Frame")({})

		for _ = 1, START(N) do
			apply<<Frame>>(instance, {})
		end
	end)

	ROOT_BENCH("bind property", function()
		local apply = require("../src/instances/bind")

		local instance = fluid.create("TextLabel")({})
		local src = source("hello")

		for _ = 1, START(N) do
			apply<<TextLabel>>(instance, {
				Text = src,
			})
		end
	end)

	ROOT_BENCH("update binding", function()
		local apply = require("../src/instances/bind")

		local instance = fluid.create("TextLabel")({})
		local src = source("hello")

		apply<<TextLabel>>(instance, {
			Text = src,
		})

		for i = 1, START(N) do
			src(tostring(i))
		end
	end)
else
	TITLE("property apply")
	print("SKIP│ Roblox Instance API unavailable")
end

TITLE("indexes()")

N /= 1024

ROOT_BENCH("indexes() all new", function()
	local data = {}

	for index = 1, N do
		data[index] = index
	end

	local src = source(data)

	START(N)

	local _list = indexes(src, function()
		return {}
	end)
end)

ROOT_BENCH("indexes() no change", function()
	local data = {}

	for index = 1, N do
		data[index] = index
	end

	local src = source(data)

	local _list = indexes(src, function()
		return {}
	end)

	START(N)

	src(data)
end)

ROOT_BENCH("indexes() all change", function()
	local data = {}

	for index = 1, N do
		data[index] = index
	end

	local src = source(data)

	local _list = indexes(src, function()
		return {}
	end)

	for index, value in data do
		data[index] = value + 1
	end

	START(N)

	src(data)
end)

ROOT_BENCH("indexes() all remove", function()
	local data = {}

	for index = 1, N do
		data[index] = index
	end

	local src = source(data)

	local _list = indexes(src, function()
		return {}
	end)

	table.clear(data)

	START(N)

	src(data)
end)

TITLE("values()")

ROOT_BENCH("values() all new", function()
	local data = {}

	for index = 1, N do
		data[index] = {}
	end

	local src = source(data)

	START(N)

	local _list = values(src, function()
		return {}
	end)
end)

ROOT_BENCH("values() no change", function()
	local data = {}

	for index = 1, N do
		data[index] = {}
	end

	local src = source(data)

	local _list = values(src, function()
		return {}
	end)

	src(src())

	START(N)

	src(data)
end)

ROOT_BENCH("values() all change", function()
	local data = {}

	for index = 1, N do
		data[index] = {}
	end

	local src = source(data)

	local _list = values(src, function()
		return {}
	end)

	src(src())

	for index = 1, N do
		local random_index = math.random(1, #data)

		data[index], data[random_index] = data[random_index], data[index]
	end

	START(N)

	src(data)
end)

ROOT_BENCH("values() all remove", function()
	local data = {}

	for index = 1, N do
		data[index] = {}
	end

	local src = source(data)

	local _list = values(src, function()
		return {}
	end)

	table.clear(data)

	START(N)

	src(data)
end)

-- TITLE("spring()")

-- local spring_supported = pcall(function()
-- 	fluid.root(function(destroy)
-- 		local src = source(0)

-- 		fluid.spring(src, 1, 1)
-- 		graph.flush_deferred_nodes()

-- 		destroy()
-- 	end)
-- end)

-- if spring_supported then
-- 	ROOT_BENCH("spring goal invalidation", function()
-- 		local src = source(0)

-- 		for _ = 1, N do
-- 			fluid.spring(src, 1, 1)
-- 		end

-- 		START(N)

-- 		src(1)
-- 	end)

-- 	ROOT_BENCH("spring goal reconciliation", function()
-- 		local src = source(0)

-- 		for _ = 1, N do
-- 			fluid.spring(src, 1, 1)
-- 		end

-- 		START(N)

-- 		src(1)
-- 		graph.flush_deferred_nodes()
-- 	end)

-- 	ROOT_BENCH("spring step", function()
-- 		local spring_step = require("../src/anim/spring").step

-- 		local src = source(0)

-- 		for _ = 1, N do
-- 			fluid.spring(src, 1, 1)
-- 		end

-- 		src(1)
-- 		graph.flush_deferred_nodes()

-- 		START(N)

-- 		spring_step(1 / 60)
-- 	end)
-- else
-- 	print("SKIP│ Spring value representation unsupported by this Lute build")
-- end

return nil
