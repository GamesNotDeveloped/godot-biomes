// The billboards of a Biomes layer (BiomesServer's far trees): a particle a cell of the layer's
// spacing around the anchor cell (rows x rows), placed as BiomesServer places a tree on the CPU
// (_chunk_points(), _grow_chunk()) - the same hash of the cell (uint arithmetic: the CPU's 64-bit
// ints masked to 32 bits), the area, the mask, the entry by its probability, the scale - stood on
// the Terrain3D's height maps (as Terrain3DData.get_height()) where the control map has the
// layer's texture (as BiomesServer._map_texture()). A particle carries its entry in CUSTOM.x; the
// draw pass (billboard_particles.gdshader) draws the entry's billboard and hides it within its
// billboard_lod_distance, where the CPU draws the models. Restarted as the anchor moves.
shader_type particles;
render_mode disable_velocity, disable_force;

// the layer's entries, at most ENTRIES_MAX (BiomesServer.FAR_ENTRIES_MAX)
#define ENTRIES_MAX 8
#define TERRAIN_TEXTURE_ANYWHERE -1

group_uniforms layer;
uniform int seed = 1;
uniform float spacing = 3.0;
uniform vec2 half_area = vec2(20.0);
// the layer's origin in the world (its node's position; the layer is not turned)
uniform vec2 origin = vec2(0.0);
uniform int entry_count = 1;
// the entries' probabilities summed up to each
uniform float cumulative[ENTRIES_MAX];
uniform vec3 scale_low[ENTRIES_MAX];
uniform vec3 scale_high[ENTRIES_MAX];
// an entry's billboard: the quad's size, and its middle's height over the ground
uniform vec2 quad_size[ENTRIES_MAX];
uniform float quad_lift[ENTRIES_MAX];
// the grid: rows x rows cells of spacing about the anchor cell, those within reach [m] of it
uniform int rows = 1;
uniform ivec2 anchor = ivec2(0);
uniform float reach = 1000.0;

group_uniforms mask;
uniform bool mask_enabled = false;
uniform sampler2D mask_texture : filter_nearest, repeat_disable;
// 0 red, 1 green, 2 blue, 3 alpha, 4 luminance (Biomes.MaskChannel)
uniform int mask_channel = 0;
uniform float mask_threshold = 0.5;
uniform bool mask_inverse = false;
uniform bool mask_affects_density = true;

group_uniforms filtering;
uniform int terrain_texture = TERRAIN_TEXTURE_ANYWHERE;
// 0 nothing grows where the autoshader is on, 1 as on the painted texture, 2 as on the texture the
// autoshader shows by the slope (Biomes.TerrainAutoshader)
uniform uint autoshader_mode = 2u;
uniform bool use_overlay = true;

group_uniforms private;
uniform uint _background_mode = 0u;
uniform bool _auto_shader = false;
uniform float _auto_slope = 1.0;
uniform float _auto_height_reduction = 0.1;
uniform int _auto_base_texture = 0;
uniform int _auto_overlay_texture = 1;
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0;
uniform float _region_size = 1024.0;
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform ivec2 _region_map_origin = ivec2(0);
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;

// BiomesServer._hash01(): the CPU's hash of a cell, its 32 bits
float hash01(int a, int b, int c, uint salt) {
	uint value = uint(a) ^ (uint(b) * 374761393u) ^ (uint(c) * 668265263u) ^ (salt * 2246822519u);
	value = value ^ (value >> 13u);
	value = value * 1274126177u;
	value = value ^ (value >> 16u);
	return float(value) / 4294967295.0;
}

// The vertex [param vertex] (in vertices) in the maps: xy within its region, z its layer, -1 none
ivec3 vertex_index(const ivec2 vertex) {
	ivec2 region = ivec2(floor(vec2(vertex) / _region_size));
	ivec2 at = region - _region_map_origin + (_region_map_size / 2);
	int layer = -1;
	if (uint(at.x | at.y) < uint(_region_map_size)) {
		layer = _region_map[at.y * _region_map_size + at.x] - 1;
	}
	return ivec3(vertex - region * int(_region_size), layer);
}

// The control map's bits at the vertex at or before [param world] (Terrain3DData.get_control()); 0
// and [param found] false where there is no region
uint control_at(const vec2 world, out bool found) {
	ivec3 index = vertex_index(ivec2(floor(world * _vertex_density)));
	found = index.z >= 0;
	return found ? floatBitsToUint(texelFetch(_control_maps, index, 0).r) : 0u;
}

// The ground's height at [param world] between its four vertices (Terrain3DData.get_height());
// [param found] false where there is no region or a hole
float ground_at(const vec2 world, out bool found) {
	uint control = control_at(world, found);
	if (!found || (control & 0x4u) != 0u) {
		found = false;
		return 0.0;
	}
	vec2 cell = world * _vertex_density;
	ivec2 first = ivec2(floor(cell));
	float corners[4];
	ivec2 offsets[4] = ivec2[](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(1, 1));
	for (int k = 0; k < 4; k++) {
		ivec3 index = vertex_index(first + offsets[k]);
		if (index.z < 0) {
			found = false;
			return 0.0;
		}
		corners[k] = texelFetch(_height_maps, index, 0).r;
	}
	vec2 weight = cell - vec2(first);
	return mix(mix(corners[0], corners[1], weight.x), mix(corners[2], corners[3], weight.x), weight.y);
}

// The mask's density at the layer's [param local] point (BiomesServer._mask_density())
float mask_density(const vec2 local) {
	if (!mask_enabled) {
		return 1.0;
	}
	vec2 uv = local / (half_area * 2.0) + 0.5;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 0.0;
	}
	ivec2 size = textureSize(mask_texture, 0);
	vec4 color = texelFetch(mask_texture, clamp(ivec2(floor(uv * vec2(size))), ivec2(0), size - 1), 0);
	float sample = mask_channel == 1 ? color.g : mask_channel == 2 ? color.b : mask_channel == 3 ? color.a
			: mask_channel == 4 ? dot(color.rgb, vec3(0.2126, 0.7152, 0.0722)) : color.r;
	float adjusted = clamp(mask_inverse ? 1.0 - sample : sample, 0.0, 1.0);
	if (!mask_affects_density) {
		return adjusted >= mask_threshold ? 1.0 : 0.0;
	}
	return adjusted <= mask_threshold ? 0.0 : (adjusted - mask_threshold) / (1.0 - mask_threshold);
}

// The tree of the grid's cell [param index]: its transform and entry; false where none stands
bool place(const uint index, out mat4 transform, out int entry) {
	ivec2 cell = anchor + ivec2(int(index % uint(rows)), int(index / uint(rows))) - ivec2(rows / 2);
	vec2 local = (vec2(cell) + vec2(hash01(seed, cell.x, cell.y, 11u), hash01(seed, cell.x, cell.y, 17u))) * spacing;
	if (abs(local.x) > half_area.x || abs(local.y) > half_area.y
			|| distance(local, (vec2(anchor) + 0.5) * spacing) > reach) {
		return false;
	}
	float density = mask_density(local);
	if (density <= 0.0 || hash01(seed, cell.x, cell.y, 7u) > density) {
		return false;
	}
	float pick = hash01(seed, cell.x, cell.y, 41u) * cumulative[entry_count - 1];
	entry = entry_count - 1;
	for (int i = 0; i < entry_count; i++) {
		if (pick <= cumulative[i]) {
			entry = i;
			break;
		}
	}
	vec2 world = local + origin;
	bool found;
	float height = ground_at(world, found);
	if (!found) {
		return false;
	}
	if (terrain_texture != TERRAIN_TEXTURE_ANYWHERE) {
		uint control = control_at(world, found);
		bool autoshaded = (control & 0x1u) != 0u;
		int base = int(control >> 27u & 0x1Fu);
		int over = int(control >> 22u & 0x1Fu);
		float blend = float(control >> 14u & 0xFFu) / 255.0;
		if (autoshaded && autoshader_mode == 0u) {
			return false;
		}
		if (autoshaded && autoshader_mode == 2u && _auto_shader) {
			base = _auto_base_texture;
			over = _auto_overlay_texture;
			bool east_found;
			bool south_found;
			float east = ground_at(world + vec2(_vertex_spacing, 0.0), east_found);
			float south = ground_at(world + vec2(0.0, _vertex_spacing), south_found);
			vec3 normal = normalize(vec3(height - east, _vertex_spacing, height - south));
			// Terrain3D's shader: lightweight.gdshader:258
			blend = clamp(_auto_slope * 2.0 * (normal.y - 1.0) + 1.0 - _auto_height_reduction * 0.01 * height, 0.0, 1.0);
		}
		if ((use_overlay && blend >= 0.5 ? over : base) != terrain_texture) {
			return false;
		}
	}
	vec3 scale = mix(min(scale_low[entry], scale_high[entry]), max(scale_low[entry], scale_high[entry]),
			vec3(hash01(seed, cell.x, cell.y, 23u), hash01(seed, cell.x, cell.y, 29u), hash01(seed, cell.x, cell.y, 31u)));
	transform = mat4(1.0);
	transform[0].x = quad_size[entry].x * scale.x;
	transform[1].y = quad_size[entry].y * scale.y;
	transform[3].xyz = vec3(world.x, height + quad_lift[entry] * scale.y, world.y);
	return true;
}

void start() {
	mat4 transform;
	int entry;
	uint index = INDEX;
	ACTIVE = place(index, transform, entry);
	if (ACTIVE) {
		TRANSFORM = transform;
		CUSTOM = vec4(float(entry), 0.0, 0.0, 0.0);
	}
}

void process() {
}
