local oklab = require("../utils/oklab")

export type Animatable =
	| number
	| CFrame
	| Color3
	| ColorSequenceKeypoint
	| DateTime
	| NumberRange
	| NumberSequenceKeypoint
	| PhysicalProperties
	| Ray
	| Rect
	| Region3
	| Region3int16
	| UDim
	| UDim2
	| Vector2
	| Vector2int16
	| Vector3
	| Vector3int16
	| vector

export type PackedValue = { number }

export type ValueType<T> = {
	count: number,
	pack: (value: T) -> PackedValue,
	unpack: (components: PackedValue) -> T,
}

local value_types = {}

local function color_to_oklab(value: Color3): vector
	return oklab.from_srgb(vector.create(value.R, value.G, value.B))
end

local function oklab_to_color(l: number, a: number, b: number): Color3
	local rgb = oklab.to_srgb(vector.create(l, a, b))

	rgb = vector.clamp(rgb, vector.zero, vector.one)

	return Color3.new(rgb.x, rgb.y, rgb.z)
end

value_types.number = {
	count = 1,

	pack = function(value: number): PackedValue
		return { value }
	end,

	unpack = function(components: PackedValue): number
		return components[1]
	end,
}

value_types.CFrame = {
	count = 7,

	pack = function(value: CFrame): PackedValue
		local axis, angle = value:ToAxisAngle()

		return {
			value.X,
			value.Y,
			value.Z,

			axis.X,
			axis.Y,
			axis.Z,

			angle,
		}
	end,

	unpack = function(components: PackedValue): CFrame
		local position = Vector3.new(components[1], components[2], components[3])

		local axis = Vector3.new(components[4], components[5], components[6])

		local angle = components[7]

		if axis.Magnitude <= 1e-8 or math.abs(angle) <= 1e-8 then
			return CFrame.new(position)
		end

		return CFrame.new(position) * CFrame.fromAxisAngle(axis.Unit, angle)
	end,
}

value_types.Color3 = {
	count = 3,

	pack = function(value: Color3): PackedValue
		local lab = color_to_oklab(value)

		return {
			lab.x,
			lab.y,
			lab.z,
		}
	end,

	unpack = function(components: PackedValue): Color3
		return oklab_to_color(components[1], components[2], components[3])
	end,
}

value_types.ColorSequenceKeypoint = {
	count = 4,

	pack = function(value: ColorSequenceKeypoint): PackedValue
		local lab = color_to_oklab(value.Value)

		return {
			lab.x,
			lab.y,
			lab.z,
			value.Time,
		}
	end,

	unpack = function(components: PackedValue): ColorSequenceKeypoint
		return ColorSequenceKeypoint.new(
			math.clamp(components[4], 0, 1),
			oklab_to_color(components[1], components[2], components[3])
		)
	end,
}

value_types.DateTime = {
	count = 1,

	pack = function(value: DateTime): PackedValue
		return {
			value.UnixTimestampMillis,
		}
	end,

	unpack = function(components: PackedValue): DateTime
		return DateTime.fromUnixTimestampMillis(math.round(components[1]))
	end,
}

value_types.NumberRange = {
	count = 2,

	pack = function(value: NumberRange): PackedValue
		return {
			value.Min,
			value.Max,
		}
	end,

	unpack = function(components: PackedValue): NumberRange
		local minimum = components[1]
		local maximum = math.max(components[2], minimum)

		return NumberRange.new(minimum, maximum)
	end,
}

value_types.NumberSequenceKeypoint = {
	count = 3,

	pack = function(value: NumberSequenceKeypoint): PackedValue
		return {
			value.Value,
			value.Time,
			value.Envelope,
		}
	end,

	unpack = function(components: PackedValue): NumberSequenceKeypoint
		return NumberSequenceKeypoint.new(math.clamp(components[2], 0, 1), components[1], math.max(components[3], 0))
	end,
}

value_types.PhysicalProperties = {
	count = 6,

	pack = function(value: PhysicalProperties): PackedValue
		return {
			value.Density,
			value.Friction,
			value.Elasticity,
			value.FrictionWeight,
			value.ElasticityWeight,
			value.AcousticAbsorption,
		}
	end,

	unpack = function(components: PackedValue): PhysicalProperties
		return PhysicalProperties.new(
			components[1],
			components[2],
			components[3],
			components[4],
			components[5],
			components[6]
		)
	end,
}

value_types.Ray = {
	count = 6,

	pack = function(value: Ray): PackedValue
		return {
			value.Origin.X,
			value.Origin.Y,
			value.Origin.Z,

			value.Direction.X,
			value.Direction.Y,
			value.Direction.Z,
		}
	end,

	unpack = function(components: PackedValue): Ray
		return Ray.new(
			Vector3.new(components[1], components[2], components[3]),
			Vector3.new(components[4], components[5], components[6])
		)
	end,
}

value_types.Rect = {
	count = 4,

	pack = function(value: Rect): PackedValue
		return {
			value.Min.X,
			value.Min.Y,
			value.Max.X,
			value.Max.Y,
		}
	end,

	unpack = function(components: PackedValue): Rect
		local min_x = math.min(components[1], components[3])
		local min_y = math.min(components[2], components[4])
		local max_x = math.max(components[1], components[3])
		local max_y = math.max(components[2], components[4])

		return Rect.new(min_x, min_y, max_x, max_y)
	end,
}

value_types.Region3 = {
	count = 6,

	pack = function(value: Region3): PackedValue
		return {
			value.CFrame.X,
			value.CFrame.Y,
			value.CFrame.Z,

			value.Size.X,
			value.Size.Y,
			value.Size.Z,
		}
	end,

	unpack = function(components: PackedValue): Region3
		local position = Vector3.new(components[1], components[2], components[3])

		local half_size =
			Vector3.new(math.abs(components[4]) / 2, math.abs(components[5]) / 2, math.abs(components[6]) / 2)

		return Region3.new(position - half_size, position + half_size)
	end,
}

value_types.Region3int16 = {
	count = 6,

	pack = function(value: Region3int16): PackedValue
		return {
			value.Min.X,
			value.Min.Y,
			value.Min.Z,

			value.Max.X,
			value.Max.Y,
			value.Max.Z,
		}
	end,

	unpack = function(components: PackedValue): Region3int16
		local x1 = math.round(components[1])
		local y1 = math.round(components[2])
		local z1 = math.round(components[3])

		local x2 = math.round(components[4])
		local y2 = math.round(components[5])
		local z2 = math.round(components[6])

		return Region3int16.new(
			Vector3int16.new(math.min(x1, x2), math.min(y1, y2), math.min(z1, z2)),
			Vector3int16.new(math.max(x1, x2), math.max(y1, y2), math.max(z1, z2))
		)
	end,
}

value_types.UDim = {
	count = 2,

	pack = function(value: UDim): PackedValue
		return {
			value.Scale,
			value.Offset,
		}
	end,

	unpack = function(components: PackedValue): UDim
		return UDim.new(components[1], math.round(components[2]))
	end,
}

value_types.UDim2 = {
	count = 4,

	pack = function(value: UDim2): PackedValue
		return {
			value.X.Scale,
			value.X.Offset,
			value.Y.Scale,
			value.Y.Offset,
		}
	end,

	unpack = function(components: PackedValue): UDim2
		return UDim2.new(components[1], math.round(components[2]), components[3], math.round(components[4]))
	end,
}

value_types.Vector2 = {
	count = 2,

	pack = function(value: Vector2): PackedValue
		return {
			value.X,
			value.Y,
		}
	end,

	unpack = function(components: PackedValue): Vector2
		return Vector2.new(components[1], components[2])
	end,
}

value_types.Vector2int16 = {
	count = 2,

	pack = function(value: Vector2int16): PackedValue
		return {
			value.X,
			value.Y,
		}
	end,

	unpack = function(components: PackedValue): Vector2int16
		return Vector2int16.new(math.round(components[1]), math.round(components[2]))
	end,
}

value_types.Vector3 = {
	count = 3,

	pack = function(value: Vector3): PackedValue
		return {
			value.X,
			value.Y,
			value.Z,
		}
	end,

	unpack = function(components: PackedValue): Vector3
		return Vector3.new(components[1], components[2], components[3])
	end,
}

value_types.Vector3int16 = {
	count = 3,

	pack = function(value: Vector3int16): PackedValue
		return {
			value.X,
			value.Y,
			value.Z,
		}
	end,

	unpack = function(components: PackedValue): Vector3int16
		return Vector3int16.new(math.round(components[1]), math.round(components[2]), math.round(components[3]))
	end,
}

value_types.vector = {
	count = 3,

	pack = function(value: vector): PackedValue
		return {
			value.x,
			value.y,
			value.z,
		}
	end,

	unpack = function(components: PackedValue): vector
		return vector.create(components[1], components[2], components[3])
	end,
}

local values = {}

function values.get<T>(type_name: string): ValueType<T>?
	return value_types[type_name]
end

function values.pack<T>(value: T): (string, PackedValue, ValueType<T>)
	local type_name = typeof(value)
	local adapter = value_types[type_name]
	assert(adapter ~= nil, `unsupported animation datatype {type_name}`)

	return type_name, adapter.pack(value), adapter
end

function values.unpack(type_name: string, components: PackedValue): any
	local adapter = value_types[type_name]
	assert(adapter ~= nil, `unsupported animation datatype {type_name}`)

	return adapter.unpack(components)
end

function values.supports(value_or_type: any): boolean
	local type_name = if type(value_or_type) == "string" then value_or_type else typeof(value_or_type)

	return value_types[type_name] ~= nil
end

values.value_types = table.freeze(value_types)
return table.freeze(values)
