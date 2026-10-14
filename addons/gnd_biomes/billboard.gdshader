// the far LOD of a Biomes entry, a quad turning to the camera around Y.
// BaseMaterial3D's BILLBOARD_FIXED_Y lights the quad by its normal, which follows the camera: looking
// towards the sun a tree was lit from behind (grey-blue), looking away fully lit. Here the quad is
// lit as a crown seen from above (the normal points up), the same from every side.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0) = 0.5;
// the generator's image is already lit (its key, fill and ambient light), and here it is lit again;
// 0.6 matches the near trees in a forest (bytom_karb_test, 2026-10-14: at 1.0 the billboards past
// 80 m were clearly lighter than the models)
uniform float brightness = 0.6;

void vertex() {
	// BaseMaterial3D's BILLBOARD_FIXED_Y with billboard_keep_scale: the instance's scale stays, or a
	// scaled tree's quad keeps its unscaled height and floats above the ground
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
	vec4 color = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = color.rgb * brightness;
	ALPHA = color.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}
