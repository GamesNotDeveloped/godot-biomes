// The far look of a Terrain3D's textures (far_ground.gd): its uniforms and far_look(), for a
// Terrain3D shader - terrain3d_far.gdshader, or a game's own that BiomesFarGround then keeps - to
// include after Terrain3D's declarations (v_vertex, _camera_pos) and apply to each texture's albedo
// as terrain3d_far.gdshader does: a FarLook made once a pixel (far_look_begin(base_ddx, base_ddy))
// handed down to accumulate_material(), and alb.rgb = far_look(id, alb.rgb, far) there.

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

// What a pixel's far look takes once, whatever its textures: its distance from the camera, the far
// albedos' place and each far albedo it samples (far_look_begin()) - far_look() is called for each
// texture of each corner, up to eight times a pixel, and a far albedo is sampled at most once
struct FarLook {
	float distance;
	vec2 uv;
	vec2 ddx;
	vec2 ddy;
	vec4 albedo[4];
	bool sampled[4];
};

FarLook far_look_begin(const vec3 base_ddx, const vec3 base_ddy) {
	FarLook look;
	// the distance the particle layers fade by (particles.gdshader: length(camera_position - pos)),
	// not the horizontal one - from above the layer is gone while the ground below is near
	look.distance = distance(v_vertex, _camera_pos);
	look.uv = v_vertex.xz * far_albedo_uv_scale;
	look.ddx = base_ddx.xz * far_albedo_uv_scale;
	look.ddy = base_ddy.xz * far_albedo_uv_scale;
	for (int i = 0; i < 4; i++) {
		look.albedo[i] = vec4(0.0);
		look.sampled[i] = false;
	}
	return look;
}

vec3 far_look(const int id, const vec3 albedo, inout FarLook look) {
	vec2 range = far_range[id];
	if (range.y <= 0.0) {
		return albedo;
	}
	float far = smoothstep(range.x, range.y, look.distance);
	if (far <= 0.0) {
		return albedo;
	}
	vec4 far_tex = vec4(albedo, 1.0);
	int slot = far_albedo_slot[id] - 1;
	if (slot >= 0 && slot < 4) {
		if (!look.sampled[slot]) {
			if (slot == 0) {
				look.albedo[slot] = textureGrad(far_albedo_1, look.uv, look.ddx, look.ddy);
			} else if (slot == 1) {
				look.albedo[slot] = textureGrad(far_albedo_2, look.uv, look.ddx, look.ddy);
			} else if (slot == 2) {
				look.albedo[slot] = textureGrad(far_albedo_3, look.uv, look.ddx, look.ddy);
			} else {
				look.albedo[slot] = textureGrad(far_albedo_4, look.uv, look.ddx, look.ddy);
			}
			look.sampled[slot] = true;
		}
		far_tex = look.albedo[slot];
	}
	return mix(albedo, mix(albedo, far_tex.rgb, far_tex.a) * far_tint[id], far);
}
