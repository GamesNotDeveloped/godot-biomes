// The draw pass of a Biomes layer's billboards (billboards.gdshader): the billboard of a particle's
// entry (CUSTOM.x), turning to the camera around Y and lit as a crown seen from above, as
// billboard.gdshader draws the CPU's. A particle in a chunk nearer to view_position than its
// entry's lod_distance (the chunk's middle, horizontally - as BiomesServer shows the models there,
// _apply_near_visibility()) or farther than max_distance is folded away.
// The draw pass's uniforms, vertex() and fragment(), for billboard_particles.gdshader and a game's
// own variant (Biomes.far_billboard_shader): one that #defines BILLBOARD_WEATHER(albedo, position) -
// a function returning the albedo under its weather at the tree's position - before including this.

#define ENTRIES_MAX 8

uniform sampler2D albedo_0 : source_color, filter_linear_mipmap;
uniform sampler2D albedo_1 : source_color, filter_linear_mipmap;
uniform sampler2D albedo_2 : source_color, filter_linear_mipmap;
uniform sampler2D albedo_3 : source_color, filter_linear_mipmap;
uniform sampler2D albedo_4 : source_color, filter_linear_mipmap;
uniform sampler2D albedo_5 : source_color, filter_linear_mipmap;
uniform sampler2D albedo_6 : source_color, filter_linear_mipmap;
uniform sampler2D albedo_7 : source_color, filter_linear_mipmap;
uniform vec4 albedo_color[ENTRIES_MAX];
// billboard.gdshader's: the image is already lit
uniform float brightness[ENTRIES_MAX];
uniform float lod_distance[ENTRIES_MAX];
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0) = 0.5;
// where BiomesServer decided last what is drawn where; its chunks' grid
uniform vec3 view_position = vec3(0.0);
uniform vec2 chunk_origin = vec2(0.0);
uniform float chunk_size = 64.0;
uniform float max_distance = 1000.0;

varying flat int entry;
// where the tree stands (the particle's origin), for a game's weather (BILLBOARD_WEATHER)
varying vec3 billboard_position;

void vertex() {
	entry = int(INSTANCE_CUSTOM.x + 0.5);
	billboard_position = MODEL_MATRIX[3].xyz;
	vec2 at = MODEL_MATRIX[3].xz;
	vec2 chunk = (floor((at - chunk_origin) / chunk_size) + 0.5) * chunk_size + chunk_origin;
	float range = distance(chunk, view_position.xz);
	if (range < lod_distance[entry] || range > max_distance) {
		VERTEX = vec3(0.0);
	}
	// billboard.gdshader's: BaseMaterial3D's BILLBOARD_FIXED_Y, the particle's scale kept
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
			vec4(0.0, 1.0, 0.0, 0.0),
			vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
			MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 color;
	if (entry == 0) {
		color = texture(albedo_0, UV);
	} else if (entry == 1) {
		color = texture(albedo_1, UV);
	} else if (entry == 2) {
		color = texture(albedo_2, UV);
	} else if (entry == 3) {
		color = texture(albedo_3, UV);
	} else if (entry == 4) {
		color = texture(albedo_4, UV);
	} else if (entry == 5) {
		color = texture(albedo_5, UV);
	} else if (entry == 6) {
		color = texture(albedo_6, UV);
	} else {
		color = texture(albedo_7, UV);
	}
	color *= albedo_color[entry];
	ALBEDO = color.rgb * brightness[entry];
#ifdef BILLBOARD_WEATHER
	ALBEDO = BILLBOARD_WEATHER(ALBEDO, billboard_position);
#endif
	ALPHA = color.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}
