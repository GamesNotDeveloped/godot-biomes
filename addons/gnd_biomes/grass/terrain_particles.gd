# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Terrain3D's extras/particle_example, as a kind of biome: blades - grass, grain - growing on the
# textures of its terrain ticked in terrain_textures, read as a Biomes reads them. The node describes
# it; BiomesServer grows it (a grid of GPU particles following the camera) - every change of the
# settings is handed to the server (get_config()). The node also sets its terrain's far look of the
# first texture it grows on (far_ground).

@tool
class_name BiomesGrass
extends Node3D


#region settings
## Auto set if attached as a child of a Terrain3D node
@export var terrain: Terrain3D:
	set(value):
		_clear_far_ground()
		terrain = value
		notify_property_list_changed()
		if _rid.is_valid():
			BiomesServer.grass_set_terrain(_rid, terrain)
		_apply_far_ground()


## the terrain's textures the instances grow on, ticked by name (a bit per
## texture id, the shader's allowed_ids)
@export_custom(PROPERTY_HINT_FLAGS, "") var terrain_textures: int = 1:
	set(value):
		_clear_far_ground()
		terrain_textures = value
		_apply_far_ground()
		_queue_configure()

## what counts where the terrain's autoshader is on (Biomes.TerrainAutoshader)
@export var terrain_autoshader: Biomes.TerrainAutoshader = Biomes.TerrainAutoshader.AUTOSHADER_TEXTURE:
	set(value):
		terrain_autoshader = value
		_queue_configure()

## where a second texture is blended over the base one over half, that one counts
@export var terrain_overlay: bool = true:
	set(value):
		terrain_overlay = value
		_queue_configure()


@export_group("Far Ground")
## past where the layer is drawn its ground is drawn as Far Texture - its own
## without one - so a field of grain stays a field of grain far away: the layer sets the terrain's
## material to terrain3d_far.gdshader with its first texture of terrain_textures, from where it starts
## fading out to its reach (min_draw_distance)
@export var far_ground: bool = false:
	set(value):
		_clear_far_ground()
		far_ground = value
		_apply_far_ground()

@export var far_texture: Texture2D:
	set(value):
		far_texture = value
		_apply_far_ground()

## multiplies Far Texture - white leaves it as it is
@export var far_tint: Color = Color.WHITE:
	set(value):
		far_tint = value
		_apply_far_ground()

@export_group("")


## Distance between instances
@export_range(0.125, 2.0, 0.015625) var instance_spacing: float = 0.5:
	set(value):
		instance_spacing = clamp(round(value * 64.0) * 0.015625, 0.125, 2.0)
		rows = maxi(int(cell_width / instance_spacing), 1)
		amount = rows * rows
		_queue_configure()


## Width of an individual cell of the grid
@export_range(8.0, 256.0, 1.0) var cell_width: float = 32.0:
	set(value):
		cell_width = clamp(value, 8.0, 256.0)
		rows = maxi(int(cell_width / instance_spacing), 1)
		amount = rows * rows
		min_draw_distance = 1.0
		_queue_configure()


## Grid width. Must be odd. 
## Higher values cull slightly better, draw further out.
@export_range(1, 15, 2) var grid_width: int = 9:
	set(value):
		grid_width = value
		particle_count = 1
		min_draw_distance = 1.0
		_queue_configure()


@export_storage var rows: int = 1

@export_storage var amount: int = 1:
	set(value):
		amount = value
		particle_count = value
		_queue_configure()


@export_range(1, 256, 1) var process_fixed_fps: int = 30:
	set(value):
		process_fixed_fps = maxi(value, 1)
		_queue_configure()


## Access to process material parameters
@export var process_material: ShaderMaterial:
	set(value):
		process_material = value
		_queue_configure()

## The mesh that each particle will render
@export var mesh: Mesh:
	set(value):
		mesh = value
		_queue_configure()

@export var shadow_mode: GeometryInstance3D.ShadowCastingSetting = (
		GeometryInstance3D.ShadowCastingSetting.SHADOW_CASTING_SETTING_ON):
	set(value):
		shadow_mode = value
		_queue_configure()


## Override material for the particle mesh
@export_custom(
	PROPERTY_HINT_RESOURCE_TYPE,
	"BaseMaterial3D,ShaderMaterial") var mesh_material_override: Material:
	set(value):
		mesh_material_override = value
		_queue_configure()


@export_group("Info")
## The minimum distance that particles will be drawn upto
## If using fade out effects like pixel alpha this is the limit to use.
@export var min_draw_distance: float = 1.0:
	set(value):
		min_draw_distance = float(cell_width * grid_width) * 0.5


## Displays current total particle count based on Cell Width and Instance Spacing
@export var particle_count: int = 1:
	set(value):
		particle_count = amount * grid_width * grid_width

#endregion

## the far look of the terrain under the layer (far_ground)
const FAR_GROUND: Script = preload("../far_ground.gd")


## The grass in BiomesServer while the node is in the tree
var _rid: RID
var _configure_queued: bool = false


## the terrain's textures by name for terrain_textures
func _validate_property(property: Dictionary) -> void:
	if not property.name == "terrain_textures":
		return
	var names: PackedStringArray = []
	if terrain and terrain.assets:
		for texture: Terrain3DTextureAsset in terrain.assets.get_texture_list():
			if texture:
				names.append("%s:%d" % [texture.name, 1 << texture.id])
	property.hint = PROPERTY_HINT_FLAGS
	property.hint_string = ",".join(names)


func _ready() -> void:
	if not terrain:
		var parent: Node = get_parent()
		if parent is Terrain3D:
			terrain = parent


func _enter_tree() -> void:
	_rid = BiomesServer.grass_create()
	BiomesServer.grass_set_scenario(_rid, get_world_3d().scenario)
	BiomesServer.grass_configure(_rid, get_config())
	BiomesServer.grass_set_terrain(_rid, terrain)
	_apply_far_ground()


func _exit_tree() -> void:
	BiomesServer.grass_free(_rid)
	_rid = RID()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_WORLD and _rid.is_valid():
		BiomesServer.grass_set_scenario(_rid, get_world_3d().scenario)


## The node's settings as BiomesServer grows them
func get_config() -> Dictionary:
	return {
		"terrain_textures": terrain_textures,
		"terrain_autoshader": terrain_autoshader,
		"terrain_overlay": terrain_overlay,
		"instance_spacing": instance_spacing,
		"cell_width": cell_width,
		"grid_width": grid_width,
		"rows": rows,
		"amount": amount,
		"process_fixed_fps": process_fixed_fps,
		"process_material": process_material,
		"mesh": mesh,
		"shadow_mode": shadow_mode,
		"mesh_material_override": mesh_material_override,
		"min_draw_distance": float(cell_width * grid_width) * 0.5,
	}


## A change of the settings reaches the server once, at the end of the frame
func _queue_configure() -> void:
	if not _rid.is_valid() or _configure_queued:
		return
	_configure_queued = true
	_configure.call_deferred()


func _configure() -> void:
	_configure_queued = false
	if _rid.is_valid():
		BiomesServer.grass_configure(_rid, get_config())


## the terrain's material drawing this layer's ground as Far Texture / its own,
## past the layer's reach (far_ground)
func _apply_far_ground() -> void:
	var texture_id: int = _far_texture_id()
	if not far_ground or texture_id < 0:
		return
	var reach: float = float(cell_width * grid_width) * 0.5
	FAR_GROUND.apply(terrain.material, texture_id, far_texture, far_tint,
			reach * float(process_material.get_shader_parameter("distance_fade_ammount")), reach)


## the far look this layer set goes, before far_ground, terrain or terrain_textures
## change - from the values it was set with, so a reloaded script clears it as well
func _clear_far_ground() -> void:
	var texture_id: int = _far_texture_id()
	if far_ground and texture_id >= 0:
		FAR_GROUND.clear(terrain.material, texture_id)


## the first texture the layer grows on, whose far look it sets (-1 none or no
## terrain to set it on)
func _far_texture_id() -> int:
	if not terrain or not terrain.material or not is_inside_tree():
		return -1
	for id: int in Terrain3DAssets.MAX_TEXTURES:
		if terrain_textures & (1 << id):
			return id
	return -1
