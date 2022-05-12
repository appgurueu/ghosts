-- Imports
local mlvec = modlib.vector
local media_paths = modlib.minetest.media.paths
-- TODO consider moving this to modlib (or perhaps even copying it here?) to remove moblib dependency
local get_rotation = moblib.get_rotation

-- Utilities
-- TODO consider move to modlib

-- Random from -1 to 1
local function signed_random()
	return math.random() * 2 - 1
end
local function random_vector()
	return vector.new(signed_random(), signed_random(), signed_random())
end
local function random_dir_vector()
	return vector.normalize(random_vector())
end

-- Configuration
local conf = modlib.mod.configuration()

-- Persistence
local data_dir = minetest.get_worldpath() .. "/data"
minetest.mkdir(data_dir)
local data = modlib.persistence.lua_log_file.new(data_dir .. "/ghosts.lua", {players = {}, night = 0}, false)
data:init()
modlib.minetest.register_globalstep(60 * 60 * 24, function()
	-- Rewrite persistence file every 24 hours
	data:rewrite()
end)
minetest.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	data:set(data.root.players, name, data.root.players[name] or {})
end)

-- Cached model & texture data
-- TODO clean these caches, most importantly the model cache (perhaps based on last access?)

local b3d_triangle_sets = setmetatable({}, {__index = function(self, filename)
	local _, ext = modlib.file.get_extension(filename)
	if not ext or  ext:lower() ~= "b3d" then
		-- Only B3D support currently
		return
	end
	local path = assert(media_paths[filename], filename)
	local model = io.open(path, "rb")
	local character = assert(modlib.b3d.read(model))
	assert(not model:read(1))
	model:close()
	local mesh = assert(character.node.mesh)
	local vertices = assert(mesh.vertices)
	for _, vertex in ipairs(vertices) do
		-- Minetest hardcodes a blocksize of 10 model units
		vertex.pos = mlvec.divide_scalar(vertex.pos, 10)
	end
	local triangle_sets = assert(mesh.triangle_sets)
	local func = modlib.func
	-- Triangle sets by texture index
	local tris_by_tex = {}
	for _, set in pairs(triangle_sets) do
		local tris = set.vertex_ids
		for _, tri in pairs(tris) do
			modlib.table.map(tri, func.curry(func.index, vertices))
		end
		local brush_id = tris.brush_id or mesh.brush_id
		local tex_id
		if brush_id then
			tex_id = assert(character.brushes[brush_id].texture_id[1])
		else
			-- No brush, default to first texture
			tex_id = 1
		end
		tris_by_tex[tex_id] = tris_by_tex[tex_id] and modlib.table.append(tris_by_tex[tex_id], tris) or tris
	end
	self[filename] = tris_by_tex
	return tris_by_tex
end})

local png_dimensions = setmetatable({}, {__index = function(self, filename)
	local _, ext = modlib.file.get_extension(filename)
	if ext:lower() ~= "png" then
		-- Only PNG support currently
		return
	end
	local media_path = media_paths[filename]
	if not media_path then
		return
	end
	local file = io.open(media_path, "rb")
	if not file then
		return
	end
	assert(file:read(8) == "\137PNG\r\n\26\10", "invalid PNG header")
	-- Skip file length
	file:read(4)
	assert(file:read(4) == "IHDR", "IHDR chunk expected")
	local width, height = file:read(4), file:read(4)
	file:close()
	local function read(dimension)
		local index = 5
		return modlib.binary.read_uint(function()
			index = index - 1
			return dimension:byte(index)
		end, 4)
	end
	local dimension = modlib.vector.new{read(width), read(height)}
	self[filename] = dimension
	return dimension
end})

-- Tries to make a reasonable guess regarding texture dimensions
local function guess_texture_dimensions(texture)
	-- If it is a combined texture, dimensions are right at the beginning
	-- It may still be overlayed later, as in "[combine:...x...:...,...=...^otherimg.png"
	-- It is reasonable to assume that the overlayed image is a multiple or a fraction of the [combine dimensions though
	local width, height = texture:match"^%[combine:(%d+)x(%d+):"
	if width then
		return modlib.vector.new{tonumber(width), tonumber(height)}
	end
	if texture:match"^%[" then
		-- Nontrivial texture modifier like [inventorycube or [lowpart
		return
	end
	-- Overlayed / modified texture. Usually, dimensions of the resulting texture will be a multiple or a fraction (if overlayed),
	-- or even the same if merely the colors are changed
	local base_image = texture:match"^(.-)%^" or texture
	if base_image and base_image ~= "" then
		return png_dimensions[base_image]
	end
end

-- Invisible entity used for attaching the sound to it: Visuals are particle-based
local modname = minetest.get_current_modname()
local sound_entity_name = modname .. ":sound"
minetest.register_entity(sound_entity_name, {
	initial_properties = {
		physical = false,
		collide_with_objects = false,
		pointable = false,
		visual_size = {x = 0, y = 0, z = 0},
		is_visible = false,
		backface_culling = true,
		static_save = false,
		damage_texture_modifier = "",
		shaded = false
	},
	on_activate = function(self, _staticdata, _dtime)
		self.timer = 0
	end,
	on_step = function(self, dtime, _moveresult)
		self.timer = self.timer + dtime
		if self.timer > (self.lifetime or math.huge) then
			self.object:remove()
		end
	end
})

local steps = conf.particles_per_metre
local function spawn_ghost(params)
	local expiration_time = assert(params.expiration_time)
	local pos = mlvec.from_minetest(params.pos)
	local velocity = assert(params.velocity)
	local triangle_sets = b3d_triangle_sets[assert(params.model)]
	if not triangle_sets then
		-- Unsupported model
		return
	end

	local rotation = get_rotation(vector.normalize(velocity))
	-- TODO as modlib doesn't have matrix support yet, we have to use axis-angle rotation
	-- which we obtain from Euler angles over quaternion representations
	local axis, angle = modlib.quaternion.to_axis_angle(
		modlib.quaternion.from_euler_rotation(vector.multiply(rotation, -1)))

	local disperse = params.disperse or 0

	if params.sound then
		local sound_object = assert(minetest.add_entity(pos, sound_entity_name))
		sound_object:set_velocity(velocity)
		minetest.sound_play({
			name = "ghosts_ghost",
			gain = 0.6 + math.random() * 0.4,
			pitch = 0.6 + math.random() * 0.4,
		}, {
			to_player = params.playername,
			object = sound_object,
			max_hear_distance = 40
		}, true)
	end

	for tex, triangles in pairs(triangle_sets) do
		local texture = assert(params.textures[tex])
		local dim = conf.fallback_resolution
		if conf.force_fallback_resolution then
			texture = texture .. "^[resize:" .. table.concat(dim, "x")
		else
			dim = guess_texture_dimensions(texture) or dim
		end
		local width, height = unpack(dim)
		-- The texture not being cached might make this "laggy" for the client the first time
		-- TODO better filtering (this is pretty much nearest neighbor)
		local pixel = texture .. "^[sheet:" .. table.concat(dim, "x") .. ":%d,%d^[resize:1x1"
		for _, tri in pairs(triangles) do
			local function transform(tri_pos)
				return mlvec.add(mlvec.rotate3(tri_pos, axis, angle), pos)
			end
			local base_pos = transform(tri[1].pos)
			local tex_base_pos = tri[1].tex_coords[1]
			local vec_x = mlvec.subtract(transform(tri[2].pos), base_pos)
			local len_x = mlvec.length(vec_x)
			local tex_vec_x = mlvec.subtract(tri[2].tex_coords[1], tex_base_pos)
			local vec_y = mlvec.subtract(transform(tri[3].pos), base_pos)
			local len_y = mlvec.length(vec_y)
			local tex_vec_y = mlvec.subtract(tri[3].tex_coords[1], tex_base_pos)
			-- Small bias of 1e-6 to avoid artifacts at triangle edges
			local bias = 1e-6
			for x = 0 + bias, 1 - bias, 1/(len_x*steps) do
				for y = 0 + bias, 1 - bias, 1/(len_y*steps) do
					if x + y > 1 then
						-- Point is not on triangle and later ones in this "scanline" can't be either
						break
					end
					-- Triangle fragment position
					local frag_pos = mlvec.add(base_pos, mlvec.add(mlvec.multiply_scalar(vec_x, x), mlvec.multiply_scalar(vec_y, y)))
					local dirvec = mlvec.subtract(pos, frag_pos)
					-- Texture coordinates
					local tex_pos = mlvec.add(tex_base_pos, mlvec.add(mlvec.multiply_scalar(tex_vec_x, x), mlvec.multiply_scalar(tex_vec_y, y)))
					local tex_x = math.floor(math.min(tex_pos[1] * width, width - 1))
					local tex_y = math.floor(math.min(tex_pos[2] * height, height - 1))
					minetest.add_particle{
						-- TODO leverage Minetest's metatable support: Omit :to_minetest()
						expirationtime = expiration_time,
						pos = frag_pos:to_minetest(),
						velocity = vector.add(velocity, vector.multiply(random_vector(), disperse)),
						acceleration = mlvec.divide_scalar(dirvec, expiration_time^2 / 2 / params.implode):to_minetest(),
						texture = pixel:format(tex_x, tex_y),
						size = 0.25,
						glow = math.random(6, 8),
						playername = params.playername
					}
				end
			end
		end
	end
	return true
end

-- Easter eggs

local is_halloween
do
	local function snap()
		local players = modlib.table.shuffle(minetest.get_connected_players())
		for index = 1, math.ceil(#players / 2) do
			local player = players[index]
			player:set_hp(0, "snap")
			spawn_ghost{
				expiration_time = 5,
				pos = player:get_pos(),
				velocity = random_vector(),
				implode = -1,
				disperse = 0.2 + math.random() * 0.1,
				-- (Audio-)visuals
				model = player:get_properties().mesh,
				textures = player:get_properties().textures,
				sound = false
			}
		end
	end

	minetest.register_on_chat_message(function(name, message)
		if modlib.text.trim_spacing(message) == "*snap*" and minetest.get_player_privs(name).server then
			snap()
		end
	end)

	local date = os.date"*t"
	is_halloween = date.day == 31 and date.month == 10
end

local function spawn_ghosts()
	for player in modlib.minetest.connected_players() do
		local name = player:get_player_name()
		for ghostname, ghost in pairs(data.root.players[name] or {}) do
			local nights_passed = data.root.night - ghost.night - 1
			if nights_passed >= conf.forget_duration_nights then
				data:set(data.root.players[name], ghostname, nil)
			elseif is_halloween or (math.random() <= conf.spawn_chance * conf.chance_reduction_per_night^nights_passed) then
				-- TODO nothing happens the very first night? 3d_armor support doesn't seem to work?
				-- Spread ghost spawning out across 10 seconds
				-- TODO make this configurable
				modlib.minetest.after(math.random() * 10, function()
					spawn_ghost{
						expiration_time = 10,
						pos = vector.add(player:get_pos(), vector.multiply(random_vector(), 3)),
						velocity = vector.multiply(random_dir_vector(), 1 + math.random() * 2),
						-- Either implode to a point or explode to 10x the size
						implode = signed_random() < 0 and 1 or -10,
						-- (Audio-)visuals
						textures = ghost.textures,
						model = ghost.model,
						sound = true,
						-- Ghosts are also publicly visible on Halloween
						playername = (not is_halloween) and player:get_player_name() or nil,
					}
				end)
			end
		end
	end
end

local last_timeofday
-- Spawn after midnight in this threshold if exactly spawning at midnight isn't possible
local midnight_duration = 0.1
minetest.register_globalstep(function()
	-- HACK first globalstep run must set last_timeofday, as it isn't available at load time
	last_timeofday = last_timeofday or assert(minetest.get_timeofday())
	local timeofday = minetest.get_timeofday()
	-- Detect midnight as a decrease in timeofday (jump from 1 to 0)
	if timeofday < last_timeofday and timeofday < midnight_duration then
		data:set_root("night", data.root.night + 1)
		spawn_ghosts()
	end
	last_timeofday = timeofday
end)

minetest.register_on_player_hpchange(function(victim, hp_change, reason)
	if victim:get_hp() + hp_change > 0 then
		-- Player survives the hit, don't haunt
		return
	end
	local hitter = (reason or {}).object
	if not (hitter and hitter:is_player()) then
		return
	end
	local props = victim:get_properties()
	data:set(data.root.players[hitter:get_player_name()], victim:get_player_name(), {
		textures = props.textures,
		model = props.mesh,
		night = data.root.night
	})
end)

-- Export API as a global variable
ghosts = {spawn_ghost = spawn_ghost}
