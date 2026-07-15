local task = (task or require("@lute/task")) :: typeof(task)

type RenderCallback = (delta_time: number) -> ()

type Connection = {
	callback: RenderCallback,
	index: number,
	connected: boolean,
}

local connections: { Connection } = {}
local cancel = task.cancel or coroutine.close

local stepping = false
local needs_compaction = false

local scheduler = {
	connections = connections,
}

local function remove_connection(connection: Connection)
	local index = connection.index
	local last_index = #connections

	if index <= 0 or index > last_index then
		return
	end

	local last_connection = connections[last_index]
	connections[last_index] = nil

	if index ~= last_index then
		connections[index] = last_connection
		last_connection.index = index
	end

	connection.index = 0
end

local function compact_connections()
	local index = 1

	while index <= #connections do
		local connection = connections[index]

		if connection.connected then
			index += 1
		else
			remove_connection(connection)
		end
	end

	needs_compaction = false
end

local function report_callback_error(err: unknown)
	local message = debug.traceback(tostring(err), 2)

	if warn ~= nil then
		warn(message)
	else
		print(message)
	end
end

function scheduler.step(delta_time: number)
	stepping = true

	local connection_count = #connections
	for index = 1, connection_count do
		local connection = connections[index]

		if connection ~= nil and connection.connected then
			xpcall(connection.callback, report_callback_error, delta_time)
		end
	end

	stepping = false

	if needs_compaction then
		compact_connections()
	end
end

function scheduler.defer<T...>(fn: (T...) -> (), ...: T...)
	return task.defer(fn, ...)
end

function scheduler.delay<T...>(delay_time: number, fn: (T...) -> (), ...: T...): thread
	return task.delay(delay_time, fn, ...)
end

function scheduler.wait(time: number?): number
	return task.wait(time)
end

function scheduler.cancel(thread: thread)
	return cancel(thread)
end

function scheduler.on_render(fn: RenderCallback): () -> ()
	local connection: Connection = {
		callback = fn,
		index = #connections + 1,
		connected = true,
	}

	connections[connection.index] = connection

	return function()
		if not connection.connected then
			return
		end

		connection.connected = false

		if stepping then
			needs_compaction = true
		else
			remove_connection(connection)
		end
	end
end

return scheduler
