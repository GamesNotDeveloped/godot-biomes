@tool
class_name Biomes
extends Node3D
## A kind of biome: models (BiomeScatterEntry) scattered over an area, on a texture of its terrain.
## The node describes it; BiomesServer grows it - around the camera, in the editor and in the game
## alike. Every change of the node's settings is handed to the server (get_config()), which grows
## the biome again. The node also sets its terrain's far look of the texture it grows on
## (far_ground) and keeps the mask painted in the editor (BiomesPanel).

const FAR_GROUND: Script = preload("./far_ground.gd")

enum MaskChannel {
    RED,
    GREEN,
    BLUE,
    ALPHA,
    LUMINANCE,
}

## terrain_texture of a layer growing on any texture
const TERRAIN_TEXTURE_ANYWHERE := -1
## what grows where the terrain's autoshader is on - nothing, as on the texture
## painted there, or as on the texture the autoshader shows by the slope (when the terrain's material
## has its autoshader on; with it off Terrain3D shows the painted one)
enum TerrainAutoshader { NOTHING, BASE_TEXTURE, AUTOSHADER_TEXTURE }
## Terrain3D announces an edit at every step of a brush; the chunks under the
## stroke are made again this long after its last step
const TERRAIN_EDIT_SETTLE_SEC := 0.25
const MASK_SAMPLE_OFFSETS: Array[Vector2] = [
    Vector2(1.0, 0.0),
    Vector2(-1.0, 0.0),
    Vector2(0.0, 1.0),
    Vector2(0.0, -1.0),
    Vector2(0.70710677, 0.70710677),
    Vector2(-0.70710677, 0.70710677),
    Vector2(0.70710677, -0.70710677),
    Vector2(-0.70710677, -0.70710677),
]

## The biome in BiomesServer while the node is in the tree
var _rid: RID
var _configure_queued := false
var _connected_entries: Array[BiomeScatterEntry] = []
var _mask_image_cache: Image
var _mask_cache_key := ""
## the area painted on the terrain since its chunks were made again
var _terrain_edited_area := AABB()
var _terrain_edited := false
var _terrain_edit_timer: Timer

@export_group("Generator")
@export var streaming_enabled := true:
    set(value):
        streaming_enabled = value
        _queue_configure()

@export_range(10.0, 2000.0, 1.0, "or_greater") var max_generation_distance: float = 120.0:
    set(value):
        max_generation_distance = maxf(value, 10.0)
        _queue_configure()

## the generation distance follows the scenery draw distance
## (SceneryStreamingServer of libmaszyna), up to max_generation_distance_cap
@export var follow_draw_distance := false:
    set(value):
        follow_draw_distance = value
        _queue_configure()
@export_range(10.0, 5000.0, 1.0, "or_greater") var max_generation_distance_cap: float = 1000.0:
    set(value):
        max_generation_distance_cap = value
        _queue_configure()

## a Terrain3D whose heights the instances stand on (terrain.data.get_height);
## a point with no terrain under it is left out. Without it the physics ray finds the surface.
@export var terrain: Node3D:
    set(value):
        _disconnect_terrain()
        _clear_far_ground()
        terrain = value
        _connect_terrain()
        notify_property_list_changed()
        if _rid.is_valid():
            BiomesServer.scatter_set_terrain(_rid, terrain)
        _apply_far_ground()

## the texture of the terrain the instances grow on (its Terrain3D texture, picked
## by name); -1 anywhere. What is painted on the terrain in the editor is followed: the chunks under
## a brush stroke are made again once the stroke has ended (TERRAIN_EDIT_SETTLE_MSEC).
@export var terrain_texture: int = TERRAIN_TEXTURE_ANYWHERE:
    set(value):
        _clear_far_ground()
        terrain_texture = value
        _queue_configure()
        _apply_far_ground()

## what counts where the terrain's autoshader is on (TerrainAutoshader)
@export var terrain_autoshader: TerrainAutoshader = TerrainAutoshader.AUTOSHADER_TEXTURE:
    set(value):
        terrain_autoshader = value
        _queue_configure()

## where a second texture is blended over the base one over half, that one counts
@export var terrain_overlay := true:
    set(value):
        terrain_overlay = value
        _queue_configure()

@export var entries: Array[BiomeScatterEntry] = []:
    set(value):
        _disconnect_entries()
        entries = value
        _connect_entries()
        _queue_configure()

@export var seed: int = 1:
    set(value):
        seed = value
        _queue_configure()

@export var area_size: Vector2 = Vector2(40.0, 40.0):
    set(value):
        area_size = Vector2(maxf(value.x, 0.0), maxf(value.y, 0.0))
        _queue_configure()

@export_range(0.1, 1024.0, 0.1, "or_greater") var average_spacing: float = 3.0:
    set(value):
        average_spacing = maxf(value, 0.1)
        _queue_configure()

@export_range(1, 1000000, 1, "or_greater") var max_instances: int = 5000:
    set(value):
        max_instances = maxi(value, 1)
        _queue_configure()

@export_enum("Off:0", "On:1", "Double-Sided:2", "Shadows Only:3") var shadow_casting: int = GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
    set(value):
        shadow_casting = clampi(value, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
        _queue_configure()

@export_subgroup("Density LOD")
@export var density_lod_enabled := false:
    set(value):
        density_lod_enabled = value
        _queue_configure()

@export_range(0.0, 100000.0, 0.1, "or_greater") var density_lod_start_distance: float = 40.0:
    set(value):
        density_lod_start_distance = maxf(value, 0.0)
        _queue_configure()

@export_range(0.0, 100000.0, 0.1, "or_greater") var density_lod_end_distance: float = 120.0:
    set(value):
        density_lod_end_distance = maxf(value, 0.0)
        _queue_configure()

@export_range(0.0, 1.0, 0.01) var density_lod_min_fraction: float = 0.2:
    set(value):
        density_lod_min_fraction = clampf(value, 0.0, 1.0)
        _queue_configure()

@export_subgroup("")

@export_group("Billboards")
## the shader the entries' billboards are drawn with by the CPU - billboard.gdshader without one; a
## game's own includes billboard.gdshaderinc (its weather on them, BILLBOARD_WEATHER)
@export var billboard_shader: Shader:
    set(value):
        billboard_shader = value
        _queue_configure()

## the shader the far trees' billboards are drawn with by the GPU - billboard_particles.gdshader
## without one; a game's own includes billboard_particles.gdshaderinc
@export var far_billboard_shader: Shader:
    set(value):
        far_billboard_shader = value
        _queue_configure()

@export_group("Far Ground")
## the ground the layer grows on (terrain_texture) drawn far away as Far Texture -
## its own texture without one - toned by Far Tint, fading in from Far Start to Far End [m from the camera],
## so a forest's floor looks like its trees where they are billboards; the terrain's material is set
## to terrain3d_far.gdshader (BiomesFarGround)
@export var far_ground := false:
    set(value):
        _clear_far_ground()
        far_ground = value
        _apply_far_ground()

@export var far_texture: Texture2D:
    set(value):
        far_texture = value
        _apply_far_ground()

## multiplies Far Texture - white leaves it as it is
@export var far_tint := Color.WHITE:
    set(value):
        far_tint = value
        _apply_far_ground()

@export_range(0.0, 5000.0, 1.0, "or_greater") var far_start: float = 80.0:
    set(value):
        far_start = value
        _apply_far_ground()

@export_range(0.0, 5000.0, 1.0, "or_greater") var far_end: float = 250.0:
    set(value):
        far_end = value
        _apply_far_ground()

## the forest's shape past where its trees are drawn: a roof of Far Texture at the height of the
## trees over the ground the layer grows on, walled by the trees' billboard where it ends - baked
## with a world's far terrain (BiomesFarCanopy), shown from where this layer's trees end
@export var far_canopy := false:
    set(value):
        far_canopy = value
        _queue_configure()

## the far canopy's roof: the forest seen from afar on a tile Far Canopy Tile wide, with its clumps
## and gaps (the Biomes panel's Generate Canopy); without one the roof is Far Texture as the terrain
## lays it
@export var far_canopy_texture: Texture2D

## the side of Far Canopy Texture's tile [m]
@export_range(10.0, 1024.0, 1.0, "or_greater") var far_canopy_tile: float = 128.0

@export_group("Collision")
@export_range(0.1, 1024.0, 0.1, "or_greater") var chunk_size: float = 16.0:
    set(value):
        chunk_size = maxf(value, 0.1)
        _queue_configure()

@export_flags_3d_physics var collision_mask: int = 1:
    set(value):
        collision_mask = value
        _queue_configure()

@export var ray_direction: Vector3 = Vector3.DOWN:
    set(value):
        ray_direction = value
        _queue_configure()

@export_range(0.0, 100000.0, 0.1, "or_greater") var ray_start_offset: float = 200.0:
    set(value):
        ray_start_offset = maxf(value, 0.0)
        _queue_configure()

@export_range(0.01, 100000.0, 0.1, "or_greater") var ray_length: float = 400.0:
    set(value):
        ray_length = maxf(value, 0.01)
        _queue_configure()

@export_group("Mask")
@export var mask_enabled := false:
    set(value):
        mask_enabled = value
        _queue_configure()

@export var mask_texture: Texture2D:
    set(value):
        mask_texture = value
        _invalidate_mask_cache()
        _queue_configure()

@export_enum("Red", "Green", "Blue", "Alpha", "Luminance") var mask_channel: int = MaskChannel.RED:
    set(value):
        mask_channel = clampi(value, MaskChannel.RED, MaskChannel.LUMINANCE)
        _queue_configure()

@export_range(0.0, 1.0, 0.01) var mask_threshold: float = 0.5:
    set(value):
        mask_threshold = clampf(value, 0.0, 1.0)
        _queue_configure()

@export var mask_inverse := false:
    set(value):
        mask_inverse = value
        _queue_configure()

@export var mask_affects_density := true:
    set(value):
        mask_affects_density = value
        _queue_configure()

@export_group("Editor")
@export_dir var billboard_output_dir: String = "res://generated/biomes_billboards"


@export_tool_button("Regenerate")
var regenerate_button := regenerate


func _enter_tree() -> void:
    _rid = BiomesServer.scatter_create()
    BiomesServer.scatter_set_scenario(_rid, get_world_3d().scenario, get_world_3d().space)
    BiomesServer.scatter_set_transform(_rid, global_transform)
    BiomesServer.scatter_set_terrain(_rid, terrain)
    BiomesServer.scatter_configure(_rid, get_config(), _get_mask_image() if mask_enabled else null)
    set_notify_transform(true)
    _connect_entries()
    _connect_terrain()
    _apply_far_ground()


func _exit_tree() -> void:
    _disconnect_entries()
    _disconnect_terrain()
    BiomesServer.scatter_free(_rid)
    _rid = RID()


func _notification(what: int) -> void:
    match what:
        NOTIFICATION_TRANSFORM_CHANGED:
            if _rid.is_valid():
                BiomesServer.scatter_set_transform(_rid, global_transform)
        NOTIFICATION_ENTER_WORLD:
            if _rid.is_valid():
                BiomesServer.scatter_set_scenario(_rid, get_world_3d().scenario, get_world_3d().space)


## The node's settings as BiomesServer grows them
func get_config() -> Dictionary:
    return {
        "entries": entries.duplicate(),
        "billboard_shader": billboard_shader,
        "far_billboard_shader": far_billboard_shader,
        "streaming_enabled": streaming_enabled,
        "max_generation_distance": max_generation_distance,
        "follow_draw_distance": follow_draw_distance,
        "max_generation_distance_cap": max_generation_distance_cap,
        "terrain_texture": terrain_texture,
        "terrain_autoshader": terrain_autoshader,
        "terrain_overlay": terrain_overlay,
        "seed": seed,
        "area_size": area_size,
        "average_spacing": average_spacing,
        "max_instances": max_instances,
        "shadow_casting": shadow_casting,
        "density_lod_enabled": density_lod_enabled,
        "density_lod_start_distance": density_lod_start_distance,
        "density_lod_end_distance": density_lod_end_distance,
        "density_lod_min_fraction": density_lod_min_fraction,
        "chunk_size": chunk_size,
        "collision_mask": collision_mask,
        "ray_direction": ray_direction,
        "ray_start_offset": ray_start_offset,
        "ray_length": ray_length,
        "mask_enabled": mask_enabled,
        "mask_channel": mask_channel,
        "mask_threshold": mask_threshold,
        "mask_inverse": mask_inverse,
        "mask_affects_density": mask_affects_density,
        "far_canopy": far_canopy,
    }


## The biome grown again from the node's settings
func regenerate() -> void:
    _configure_queued = false
    if _rid.is_valid():
        BiomesServer.scatter_configure(_rid, get_config(), _get_mask_image() if mask_enabled else null)


## A change of the settings reaches the server once, at the end of the frame
func _queue_configure() -> void:
    if not _rid.is_valid() or _configure_queued:
        return
    _configure_queued = true
    regenerate.call_deferred()


func _connect_entries() -> void:
    for entry in entries:
        if entry and not entry.changed.is_connected(_queue_configure):
            entry.changed.connect(_queue_configure)
            _connected_entries.append(entry)


func _disconnect_entries() -> void:
    for entry in _connected_entries:
        if is_instance_valid(entry) and entry.changed.is_connected(_queue_configure):
            entry.changed.disconnect(_queue_configure)
    _connected_entries.clear()


## the terrain's textures by name for terrain_texture
func _validate_property(property: Dictionary) -> void:
    if property.name != "terrain_texture":
        return
    var names := PackedStringArray(["Anywhere:%d" % TERRAIN_TEXTURE_ANYWHERE])
    var assets: Resource = terrain.get("assets") if terrain != null else null
    if assets != null:
        for texture: Resource in assets.get_texture_list():
            if texture != null:
                names.append("%s:%d" % [texture.name, texture.id])
    property.hint = PROPERTY_HINT_ENUM
    property.hint_string = ",".join(names)


## the terrain's material drawing the ground of terrain_texture as Far Texture /
## its own texture, toned, far away (far_ground); a layer growing anywhere has no ground of its own
func _apply_far_ground() -> void:
    if not far_ground or not _has_far_ground_terrain():
        return
    FAR_GROUND.apply(terrain.material, terrain_texture, far_texture, far_tint, far_start, far_end)


## the far look this layer set goes, before far_ground, terrain or terrain_texture
## change - from the values it was set with, so a reloaded script clears it as well
func _clear_far_ground() -> void:
    if far_ground and _has_far_ground_terrain():
        FAR_GROUND.clear(terrain.material, terrain_texture)


func _has_far_ground_terrain() -> bool:
    return is_inside_tree() and terrain != null and terrain.get("material") != null \
            and terrain_texture != TERRAIN_TEXTURE_ANYWHERE


## in the editor the painting of the terrain is followed (_on_terrain_edited())
func _connect_terrain() -> void:
    if Engine.is_editor_hint() and is_inside_tree() and terrain != null and terrain.data != null:
        if not terrain.data.maps_edited.is_connected(_on_terrain_edited):
            terrain.data.maps_edited.connect(_on_terrain_edited)


func _disconnect_terrain() -> void:
    if terrain != null and terrain.data != null and terrain.data.maps_edited.is_connected(_on_terrain_edited):
        terrain.data.maps_edited.disconnect(_on_terrain_edited)


## a step of a brush on the terrain - its area grows again once the stroke has ended
## (TERRAIN_EDIT_SETTLE_SEC after its last step)
func _on_terrain_edited(area: AABB) -> void:
    _terrain_edited_area = _terrain_edited_area.merge(area) if _terrain_edited else area
    _terrain_edited = true
    if not _terrain_edit_timer:
        _terrain_edit_timer = Timer.new()
        _terrain_edit_timer.one_shot = true
        _terrain_edit_timer.wait_time = TERRAIN_EDIT_SETTLE_SEC
        _terrain_edit_timer.timeout.connect(_on_terrain_edit_settled)
        add_child(_terrain_edit_timer, false, INTERNAL_MODE_FRONT)
    _terrain_edit_timer.start()


func _on_terrain_edit_settled() -> void:
    _terrain_edited = false
    if _rid.is_valid():
        BiomesServer.scatter_drop_area(_rid, _terrain_edited_area)


func get_mask_texture_path() -> String:
    if mask_texture == null:
        return ""
    return mask_texture.resource_path


func get_mask_image_copy() -> Image:
    var image := _get_mask_image()
    if image == null or image.is_empty():
        return Image.create(1, 1, false, Image.FORMAT_RGBA8)
    return image.duplicate()


func world_to_mask_uv(world_position: Vector3) -> Vector2:
    return local_to_mask_uv(to_local(world_position))


func local_to_mask_uv(local_position: Vector3) -> Vector2:
    if area_size.x <= 0.0 or area_size.y <= 0.0:
        return Vector2(-1.0, -1.0)

    return Vector2(
        (local_position.x / area_size.x) + 0.5,
        (local_position.z / area_size.y) + 0.5
    )


func sample_mask_value_at_world_position(world_position: Vector3, radius: float = 0.0) -> float:
    if not mask_enabled or mask_texture == null:
        return 1.0
    if radius > 0.0:
        return _sample_mask_average_value_at_world_position(world_position, radius)
    return _sample_single_mask_value_at_world_position(world_position)


func _sample_mask_average_value_at_world_position(world_position: Vector3, radius: float) -> float:
    var total := _sample_single_mask_value_at_world_position(world_position)
    var sample_count := 1.0
    for offset in MASK_SAMPLE_OFFSETS:
        total += _sample_single_mask_value_at_world_position(
            world_position + Vector3(offset.x * radius, 0.0, offset.y * radius)
        )
        sample_count += 1.0
    return total / sample_count


func _sample_single_mask_value_at_world_position(world_position: Vector3) -> float:
    var sample := _sample_mask_value_from_local_position(to_local(world_position), -1.0)
    if sample < 0.0:
        return 0.0
    return 1.0 - sample if mask_inverse else sample


func preview_mask_image(image: Image) -> void:
    _set_mask_cache_from_image(image)
    _queue_configure()


func set_mask_image(image: Image, save_to_disk := true) -> void:
    _set_mask_cache_from_image(image)
    if save_to_disk:
        _save_mask_image_to_disk(image)
        _mask_cache_key = _build_mask_cache_key()
    _queue_configure()


func create_mask_texture_file(path: String, resolution: int) -> bool:
    if path.is_empty() or resolution <= 0:
        return false

    var image := Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
    image.fill(Color(0.0, 0.0, 0.0, 1.0))
    if image.save_png(path) != OK:
        return false

    _set_mask_cache_from_image(image)
    _mask_cache_key = _build_mask_cache_key()
    mask_enabled = true
    return true


func assign_mask_texture(texture: Texture2D, enable_mask := true) -> void:
    mask_texture = texture
    mask_enabled = enable_mask
    notify_property_list_changed()
    _queue_configure()


func paint_mask_circle_on_image(image: Image, local_position: Vector3, radius_world: float, value: float, hardness: float = 0.35, opacity: float = 1.0) -> bool:
    if image == null or image.is_empty():
        return false

    var uv := local_to_mask_uv(local_position)
    if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
        return false

    var width := image.get_width()
    var height := image.get_height()
    if width <= 0 or height <= 0:
        return false

    var center_x := int(round(uv.x * float(width - 1)))
    var center_y := int(round(uv.y * float(height - 1)))
    var radius_px := _world_radius_to_pixel_radius(radius_world, width, height)
    var radius_sq := radius_px * radius_px
    var clamped_hardness := clampf(hardness, 0.0, 1.0)
    var clamped_opacity := clampf(opacity, 0.0, 1.0)
    var inner_radius := float(radius_px) * clamped_hardness
    var changed := false

    for y in range(maxi(0, center_y - radius_px), mini(height, center_y + radius_px + 1)):
        for x in range(maxi(0, center_x - radius_px), mini(width, center_x + radius_px + 1)):
            var dx := x - center_x
            var dy := y - center_y
            var distance_sq := (dx * dx) + (dy * dy)
            if distance_sq > radius_sq:
                continue
            var distance := sqrt(float(distance_sq))
            var influence := 1.0
            if radius_px > 0 and distance > inner_radius:
                var outer_range := maxf(float(radius_px) - inner_radius, 0.0001)
                var falloff_t := clampf((distance - inner_radius) / outer_range, 0.0, 1.0)
                influence = 1.0 - _smoothstep(0.0, 1.0, falloff_t)
            influence *= clamped_opacity
            if influence <= 0.0:
                continue
            var color := image.get_pixel(x, y)
            var next_color := _apply_mask_paint(color, value, influence)
            if next_color != color:
                image.set_pixel(x, y, next_color)
                changed = true
    return changed


func _sample_mask_value_from_local_position(local_position: Vector3, outside_value: float) -> float:
    var uv := local_to_mask_uv(local_position)
    return _sample_mask_value_from_uv(uv, outside_value)


func _sample_mask_value_from_uv(uv: Vector2, outside_value: float) -> float:
    var image := _get_mask_image()
    if image == null or image.is_empty():
        return 1.0
    if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
        return outside_value

    var width := image.get_width()
    var height := image.get_height()
    if width <= 0 or height <= 0:
        return 1.0

    var pixel_x := clampi(int(floor(uv.x * float(width))), 0, width - 1)
    var pixel_y := clampi(int(floor(uv.y * float(height))), 0, height - 1)
    return _sample_mask_channel(image.get_pixel(pixel_x, pixel_y))


func _sample_mask_channel(color: Color) -> float:
    return BiomesServer.mask_channel_value(color, mask_channel)


func _apply_mask_paint(color: Color, value: float, influence: float) -> Color:
    var clamped_value := clampf(value, 0.0, 1.0)
    var clamped_influence := clampf(influence, 0.0, 1.0)
    match mask_channel:
        MaskChannel.RED:
            color.r = lerpf(color.r, clamped_value, clamped_influence)
        MaskChannel.GREEN:
            color.g = lerpf(color.g, clamped_value, clamped_influence)
        MaskChannel.BLUE:
            color.b = lerpf(color.b, clamped_value, clamped_influence)
        MaskChannel.ALPHA:
            color.a = lerpf(color.a, clamped_value, clamped_influence)
        MaskChannel.LUMINANCE:
            color.r = lerpf(color.r, clamped_value, clamped_influence)
            color.g = lerpf(color.g, clamped_value, clamped_influence)
            color.b = lerpf(color.b, clamped_value, clamped_influence)
    return color


func _smoothstep(edge0: float, edge1: float, x: float) -> float:
    var t := clampf(inverse_lerp(edge0, edge1, x), 0.0, 1.0)
    return t * t * (3.0 - (2.0 * t))


func _world_radius_to_pixel_radius(radius_world: float, width: int, height: int) -> int:
    var world_per_pixel_x := area_size.x / maxf(float(width), 1.0)
    var world_per_pixel_y := area_size.y / maxf(float(height), 1.0)
    var world_per_pixel := maxf(minf(world_per_pixel_x, world_per_pixel_y), 0.0001)
    return maxi(1, int(ceil(radius_world / world_per_pixel)))


func _get_mask_image() -> Image:
    if mask_texture == null:
        return null

    # outside the editor the mask is not painted, and the key reads the file's time
    # for every sample, on the worker threads too
    if not Engine.is_editor_hint() and _mask_image_cache != null and not _mask_image_cache.is_empty():
        return _mask_image_cache
    var cache_key := _build_mask_cache_key()
    if _mask_image_cache != null and _mask_cache_key == cache_key and not _mask_image_cache.is_empty():
        return _mask_image_cache

    var image := mask_texture.get_image()
    if image == null or image.is_empty():
        return null
    if image.is_compressed():
        var decompress_error := image.decompress()
        if decompress_error != OK:
            push_warning("Biomes mask could not be decompressed for sampling: %s" % cache_key)
            return null
    if image.get_format() != Image.FORMAT_RGBA8:
        image.convert(Image.FORMAT_RGBA8)

    _mask_image_cache = image
    _mask_cache_key = cache_key
    return _mask_image_cache


func _set_mask_cache_from_image(image: Image) -> void:
    if image == null or image.is_empty():
        _mask_image_cache = null
        _mask_cache_key = ""
        return

    _mask_image_cache = image.duplicate()
    if _mask_image_cache.is_compressed():
        _mask_image_cache.decompress()
    if _mask_image_cache.get_format() != Image.FORMAT_RGBA8:
        _mask_image_cache.convert(Image.FORMAT_RGBA8)
    _mask_cache_key = _build_mask_cache_key()


func _save_mask_image_to_disk(image: Image) -> void:
    var path := get_mask_texture_path()
    if path.is_empty():
        return
    image.save_png(path)


func _load_mask_texture_from_path(path: String) -> void:
    var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
    if loaded is Texture2D:
        mask_texture = loaded
    else:
        mask_texture = ImageTexture.create_from_image(_mask_image_cache)


func _reload_mask_texture_from_disk() -> void:
    var path := get_mask_texture_path()
    if path.is_empty():
        return
    _load_mask_texture_from_path(path)


func _invalidate_mask_cache() -> void:
    _mask_image_cache = null
    _mask_cache_key = ""


func _build_mask_cache_key() -> String:
    var path := get_mask_texture_path()
    var modified := ""
    if not path.is_empty() and FileAccess.file_exists(path):
        modified = str(FileAccess.get_modified_time(path))
    return "%s|%s" % [_resource_id(mask_texture), modified]


func _resource_id(resource: Resource) -> String:
    if resource == null:
        return ""
    return "%s#%s" % [resource.resource_path, resource.get_instance_id()]

