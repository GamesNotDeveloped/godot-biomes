@tool
extends RefCounted
class_name BiomesFarGround
## The far look of a texture of a Terrain3D (terrain3d_far.gdshader): a layer of plants makes the
## ground it grows on look like the plants past where it draws them - a field like its grain, a forest
## like its trees. Each layer writes only the entries of its own texture, so the layers keep theirs.
## A Terrain3D shader of a game's own with the far look (terrain3d_far.gdshaderinc included) is kept:
## a terrain needing more of its shader than the far look - the game's weather - keeps it.

const SHADER: Shader = preload("./terrain3d_far.gdshader")
const TEXTURES: int = 32
## The shader's far_albedo_1 .. far_albedo_4
const ALBEDO_SLOTS: int = 4
## The uniform a shader with the far look declares (terrain3d_far.gdshaderinc)
const FAR_RANGE: StringName = &"far_range"


## Turns the texture [param texture_id] of the terrain's [param material] into [param albedo] - itself
## without one - toned by [param tint], from [param start] to [param end] metres from the camera
static func apply(material: Terrain3DMaterial, texture_id: int, albedo: Texture2D, tint: Color,
        start: float, end: float) -> void:
    if not has_far_look(material):
        material.shader_override = SHADER
    material.shader_override_enabled = true
    _refresh_params(material)
    var slot: int = _albedo_slot(material, texture_id, albedo) if albedo else 0
    _set_entry(material, "far_range", PackedVector2Array(), texture_id, Vector2(start, maxf(end, start + 1.0)))
    # the shader's array takes no source_color hint
    var linear: Color = tint.srgb_to_linear()
    _set_entry(material, "far_tint", PackedVector3Array(), texture_id, Vector3(linear.r, linear.g, linear.b))
    _set_entry(material, "far_albedo_slot", PackedInt32Array(), texture_id, slot)


## The texture [param texture_id] looks the same at any distance again
static func clear(material: Terrain3DMaterial, texture_id: int) -> void:
    if not has_far_look(material):
        return
    _refresh_params(material)
    _set_entry(material, "far_range", PackedVector2Array(), texture_id, Vector2.ZERO)
    _set_entry(material, "far_albedo_slot", PackedInt32Array(), texture_id, 0)


## The terrain's [param material] is drawn with a shader that has the far look: SHADER, or a game's
## own including terrain3d_far.gdshaderinc
static func has_far_look(material: Terrain3DMaterial) -> bool:
    var shader: Shader = material.shader_override
    return shader and shader.get_shader_uniform_list().any(
            func(uniform: Dictionary) -> bool: return uniform["name"] == FAR_RANGE)


## Terrain3DMaterial takes only the parameters it has listed from its shader (its _active_params, made
## by _get_property_list) and drops the others without a word - after the shader was set or changed
## they are not listed yet
static func _refresh_params(material: Terrain3DMaterial) -> void:
    material.get_property_list()


## One entry of an array parameter; [param empty] is the array's type, used while the material has none
static func _set_entry(material: Terrain3DMaterial, name: String, empty: Variant, texture_id: int, value: Variant) -> void:
    var values: Variant = material.get_shader_param(name)
    if not typeof(values) == typeof(empty):
        values = empty
    if not values.size() == TEXTURES:
        values.resize(TEXTURES)
    values[texture_id] = value
    material.set_shader_param(name, values)


## The far albedo slot showing [param albedo] for [param texture_id]: one already showing it, else one
## no other texture uses; 0 (its own albedo) when all are taken
static func _albedo_slot(material: Terrain3DMaterial, texture_id: int, albedo: Texture2D) -> int:
    var ranges: Variant = material.get_shader_param("far_range")
    var slots: Variant = material.get_shader_param("far_albedo_slot")
    var used: Dictionary = {}
    if typeof(ranges) == TYPE_PACKED_VECTOR2_ARRAY and typeof(slots) == TYPE_PACKED_INT32_ARRAY:
        for id in mini(ranges.size(), slots.size()):
            if not id == texture_id and ranges[id].y > 0.0 and slots[id] > 0:
                used[slots[id]] = true
    for slot in range(1, ALBEDO_SLOTS + 1):
        if used.has(slot) and material.get_shader_param("far_albedo_%d" % slot) == albedo:
            return slot
    for slot in range(1, ALBEDO_SLOTS + 1):
        if not used.has(slot):
            material.set_shader_param("far_albedo_%d" % slot, albedo)
            return slot
    push_warning("Biomes: no far albedo slot left for texture %d, its own is toned" % texture_id)
    return 0
