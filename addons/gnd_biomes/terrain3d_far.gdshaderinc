// The far look of a Terrain3D's textures (far_ground.gd): its uniforms and far_look(), for a
// Terrain3D shader - terrain3d_far.gdshader, or a game's own that BiomesFarGround then keeps - to
// include after Terrain3D's declarations (v_vertex, _camera_pos) and apply to each texture's albedo
// as terrain3d_far.gdshader does (alb.rgb = far_look(id, alb.rgb, base_ddx, base_ddy)).

// the far look of each texture of the terrain (id 0-31): past far_range.x [m from
// the camera] it turns into its far albedo (far_albedo_slot: far_albedo_1-4, 0 none: its own albedo)
// toned by far_tint, completely at far_range.y; a texture whose far_range.y is 0 has none. far_tint
// is linear (far_ground.gd converts it).
// Each layer of plants writes the entries of its own texture (far_ground.gd).
uniform vec2 far_range[32];
uniform vec3 far_tint[32];
uniform int far_albedo_slot[32];
uniform sampler2D far_albedo_1 : source_color, hint_default_transparent, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D far_albedo_2 : source_color, hint_default_transparent, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D far_albedo_3 : source_color, hint_default_transparent, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D far_albedo_4 : source_color, hint_default_transparent, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float far_albedo_uv_scale = 0.1;

vec3 far_look(const int id, const vec3 albedo, const vec3 base_ddx, const vec3 base_ddy) {
	vec2 range = far_range[id];
	if (range.y <= 0.0) {
		return albedo;
	}
	// the distance the particle layers fade by (particles.gdshader: length(camera_position - pos)),
	// not the horizontal one - from above the layer is gone while the ground below is near
	float far = smoothstep(range.x, range.y, distance(v_vertex, _camera_pos));
	if (far <= 0.0) {
		return albedo;
	}
	vec2 far_uv = v_vertex.xz * far_albedo_uv_scale;
	vec2 far_ddx = base_ddx.xz * far_albedo_uv_scale;
	vec2 far_ddy = base_ddy.xz * far_albedo_uv_scale;
	vec4 far_tex = vec4(albedo, 1.0);
	int slot = far_albedo_slot[id];
	if (slot == 1) {
		far_tex = textureGrad(far_albedo_1, far_uv, far_ddx, far_ddy);
	} else if (slot == 2) {
		far_tex = textureGrad(far_albedo_2, far_uv, far_ddx, far_ddy);
	} else if (slot == 3) {
		far_tex = textureGrad(far_albedo_3, far_uv, far_ddx, far_ddy);
	} else if (slot == 4) {
		far_tex = textureGrad(far_albedo_4, far_uv, far_ddx, far_ddy);
	}
	return mix(albedo, mix(albedo, far_tex.rgb, far_tex.a) * far_tint[id], far);
}
