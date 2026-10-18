@tool
class_name BiomeScatterEntry
extends Resource


func _emit_if_changed(current_value: Variant, next_value: Variant) -> Variant:
	if current_value == next_value:
		return current_value
	emit_changed()
	return next_value


@export var mesh: Mesh:
	set(value):
		mesh = _emit_if_changed(mesh, value)

@export var mesh_scene: PackedScene:
	set(value):
		mesh_scene = _emit_if_changed(mesh_scene, value)

## the model simplified, with its own materials (the Biomes panel's Generate Mid Meshes): drawn
## instead of it from mid_lod_distance to billboard_lod_distance. Empty: the model all the way.
@export var mid_scene: PackedScene:
	set(value):
		mid_scene = _emit_if_changed(mid_scene, value)

@export_range(0.0, 100000.0, 0.1, "or_greater") var mid_lod_distance: float = 25.0:
	set(value):
		mid_lod_distance = _emit_if_changed(mid_lod_distance, maxf(value, 0.0))

## what the model's shadow is drawn with, alone (the Biomes panel's Generate Shadow Meshes): a
## simplified model, without wind - the model itself then casts none. Empty: the model casts its own.
@export var shadow_scene: PackedScene:
	set(value):
		shadow_scene = _emit_if_changed(shadow_scene, value)

@export var billboard_mesh: Mesh:
	set(value):
		billboard_mesh = _emit_if_changed(billboard_mesh, value)

@export var billboard_scene: PackedScene:
	set(value):
		billboard_scene = _emit_if_changed(billboard_scene, value)

@export_range(0.0, 1000.0, 0.01, "or_greater") var probability: float = 1.0:
	set(value):
		probability = _emit_if_changed(probability, maxf(value, 0.0))

@export_range(0.0, 100000.0, 0.1, "or_greater") var billboard_lod_distance: float = 60.0:
	set(value):
		billboard_lod_distance = _emit_if_changed(billboard_lod_distance, maxf(value, 0.0))

## how light this entry's billboards are (billboard.gdshader's brightness). The
## generator's image is already lit, and is lit again in the scene. A shader parameter: it is set on
## the billboards drawn, with no changed signal, so Biomes does not regenerate.
@export_range(0.0, 2.0, 0.01) var billboard_brightness: float = 0.6:
	set(value):
		billboard_brightness = maxf(value, 0.0)
		for material in billboard_materials:
			material.set_shader_parameter("brightness", billboard_brightness)

## the materials of this entry's billboards drawn now, filled by Biomes
var billboard_materials: Array[ShaderMaterial] = []

@export var scale_min: Vector3 = Vector3.ONE:
	set(value):
		scale_min = _emit_if_changed(scale_min, value)

@export var scale_max: Vector3 = Vector3.ONE:
	set(value):
		scale_max = _emit_if_changed(scale_max, value)
