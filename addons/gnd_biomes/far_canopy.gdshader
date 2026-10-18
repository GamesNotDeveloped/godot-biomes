// the far canopy of a Biomes layer, baked with a world's far terrain (BiomesFarCanopy): a forest past
// where its trees are drawn - a roof at the trees' height (COLOR.r 0) of roof_texture laid over the
// world (UV2: world X, Z) a tile every 1 / roof_uv_scale metres, patched brighter and darker by the
// same texture MACRO_SCALE times larger (as Terrain3D's macro variation), and walls
// where the forest ends (COLOR.r 1) of the trees' billboard side by side. It shows from
// gnd_canopy_begin on [m from the camera, horizontal, as the trees' chunks are planned; BiomesServer
// sets it to where the layer's trees end], fading in by a dither over FADE before it.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D roof_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float roof_uv_scale = 0.1;
// the layer's far tint, as the terrain's far look tones its far texture
uniform vec4 far_tint : source_color = vec4(1.0);
uniform sampler2D wall_texture : source_color, filter_linear_mipmap, repeat_enable;
// as billboard.gdshader's: the wall's image is already lit
uniform float wall_brightness = 0.6;
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0) = 0.5;
global uniform float gnd_canopy_begin;
const float FADE = 100.0;
// the macro variation: the roof's texture so many times larger, its patches over the roof's mean so
// strong
const float MACRO_SCALE = 1.0 / 16.0;
const float MACRO_STRENGTH = 0.6;
// a mip level past the smallest: the texture's mean
const float MEAN_LOD = 16.0;

// a 4x4 Bayer matrix: the order the screen's pixels are drawn in over the fade
const float DITHER[16] = { 0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0 };

varying float wall;

void vertex() {
	wall = COLOR.r;
}

void fragment() {
	// from the camera by the view's own vector, never the world's large coordinates
	float distance = length((mat3(INV_VIEW_MATRIX) * VERTEX).xz);
	// the share of the screen's pixels drawn grows over the fade
	float shown = smoothstep(gnd_canopy_begin - FADE, gnd_canopy_begin, distance);
	ivec2 cell = ivec2(FRAGCOORD.xy) % 4;
	if (shown < (DITHER[cell.y * 4 + cell.x] + 0.5) / 16.0) {
		discard;
	}
	if (wall > 0.5) {
		vec4 color = texture(wall_texture, UV);
		ALBEDO = color.rgb * wall_brightness;
		ALPHA = color.a;
		// lit as billboard.gdshader lights a tree: as a crown seen from above
		NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	} else {
		// UV2: the vertex's world X and Z, worked out in the world's precision (BiomesFarCanopy)
		vec2 uv = UV2 * roof_uv_scale;
		vec3 mean = textureLod(roof_texture, uv, MEAN_LOD).rgb;
		vec3 macro = texture(roof_texture, uv * MACRO_SCALE).rgb / max(mean, vec3(0.001));
		ALBEDO = texture(roof_texture, uv).rgb * mix(vec3(1.0), macro, MACRO_STRENGTH) * far_tint.rgb;
		ALPHA = 1.0;
	}
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
}
