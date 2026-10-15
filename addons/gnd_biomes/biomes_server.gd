@tool
extends Node
## BiomesServer (autoload): grows the biomes. A node describes a kind of biome and hands it to the
## server; the server grows it around the camera, with RenderingServer's objects alone - no nodes:
## - a scatter (Biomes: models - trees, flowers - over an area, on a texture of its terrain;
##   scatter_create(), scatter_configure()): a chunk at a time, its points worked out on the worker
##   threads, stood on the terrain and drawn as MultiMeshes (a near one and a billboard one per model
##   part); the chunks are planned on a timer (STREAM_INTERVAL), never per frame;
## - grass (BiomesGrass: blades - grass, grain - on textures of its terrain; grass_create(),
##   grass_configure()): a grid of GPU particles placed by the process material from the terrain's
##   maps, moved after the camera - the one thing looked at every frame, while there is grass.

const BILLBOARD_SHADER: Shader = preload("./billboard.gdshader")
## How often the camera is looked at and the chunks planned [s]
const STREAM_INTERVAL: float = 0.1
## The frames of a STREAM_INTERVAL at 60 fps: a biome builds its chunks_per_frame per frame, so many
## times that a tick
const STREAM_FRAMES: int = 6
## terrain_texture of a biome growing on any texture
const TERRAIN_TEXTURE_ANYWHERE: int = -1
## Terrain3D's autoshader defaults, of a material that does not set them
## (addons/terrain_3d/extras/shaders/lightweight.gdshader:62-65, as its own shader)
const AUTO_SLOPE_DEFAULT: float = 1.0
const AUTO_HEIGHT_REDUCTION_DEFAULT: float = 0.1
const AUTO_BASE_TEXTURE_DEFAULT: int = 0
const AUTO_OVERLAY_TEXTURE_DEFAULT: int = 1
## Terrain3D shows the overlay texture where it is blended over this
const OVERLAY_BLEND_SHOWN: float = 0.5
const HASH_MASK: int = 0xFFFFFFFF
## Floats of an instance's transform in a MultiMesh buffer (3x4)
const TRANSFORM_FLOATS: int = 12
## Grass: a particle lives this long - the grid restarts it whenever it moves [s]
const PARTICLES_LIFETIME: float = 600.0
## Terrain3D's region map, regions along its side
const REGION_MAP_SIZE: int = 32
## The project's global shader parameter that turns the biomes' shadows off when false
const HIGH_QUALITY_PARAMETER: StringName = &"gnd_high_quality_foliage"

enum MaskChannel { RED, GREEN, BLUE, ALPHA, LUMINANCE }
## What grows where the terrain's autoshader is on - nothing, as on the texture painted there, or
## as on the texture the autoshader shows by the slope
enum TerrainAutoshader { NOTHING, BASE_TEXTURE, AUTOSHADER_TEXTURE }


## A biome of blades (BiomesGrass): a grid_width x grid_width grid of particles, each cell_width
## wide, following the camera
class Grass:
    ## BiomesGrass.get_config()
    var config: Dictionary = {}
    var scenario: RID
    var terrain_id: int = 0
    ## The terrain's data whose maps_changed the grass follows: a Terrain3D may make its data anew
    ## (set_data_directory()), so it is the object followed, not the terrain's current one
    var maps_data_id: int = 0
    var particles: Array[RID] = []
    var instances: Array[RID] = []
    var offsets: Array[Vector3] = []
    ## Where the camera was when the grid was last placed; INF: not placed yet
    var last_position: Vector3 = Vector3.INF


## A biome of scattered models (Biomes)
class Scatter:
    ## The node's settings (Biomes.get_config())
    var config: Dictionary = {}
    ## Its entries made drawable (_resolve_entries())
    var entries: Array[Dictionary] = []
    var mask: Image = null
    var transform: Transform3D = Transform3D.IDENTITY
    var scenario: RID
    ## The physics space the ray finds the surface in, without a terrain
    var space: RID
    var terrain_id: int = 0
    ## chunk coords -> {multimeshes: Array[RID], instances: Array[RID], count: int, visible: int, center: Vector3}
    var chunks: Dictionary = {}
    ## chunk coords -> WorkerThreadPool task id
    var tasks: Dictionary = {}
    ## chunk coords -> Array of points, written by the worker threads
    var points: Dictionary = {}
    var mutex: Mutex = Mutex.new()
    ## Raised by every configuration: a task of an earlier one leaves its points unused
    var generation: int = 0
    var high_quality: bool = true


var _scatters: Dictionary = {}
## RID -> Grass
var _grasses: Dictionary = {}
var _timer: Timer
var _high_quality: bool = true


## The foliage's quality (HIGH_QUALITY_PARAMETER, which the shaders read too): shadows and detail of
## the scatters; applied at the next streaming
func set_high_quality(enabled: bool) -> void:
    _high_quality = enabled
    RenderingServer.global_shader_parameter_set(HIGH_QUALITY_PARAMETER, enabled)


func is_high_quality() -> bool:
    return _high_quality


func _ready() -> void:
    # as the project declares it; RenderingServer.global_shader_parameter_get() is the editor's alone
    # (in a game it logs an error at every call)
    var declared: Variant = ProjectSettings.get_setting("shader_globals/" + HIGH_QUALITY_PARAMETER)
    _high_quality = bool(declared.get("value", true)) if declared is Dictionary else true
    _timer = Timer.new()
    _timer.wait_time = STREAM_INTERVAL
    _timer.timeout.connect(_stream)
    add_child(_timer)
    _timer.start()


func _exit_tree() -> void:
    for rid: RID in _scatters.keys():
        scatter_free(rid)
    for rid: RID in _grasses.keys():
        grass_free(rid)


func grass_create() -> RID:
    var rid: RID = rid_from_int64(rid_allocate_id())
    _grasses[rid] = Grass.new()
    if _grasses.size() == 1:
        get_tree().process_frame.connect(_follow_camera)
    return rid


func grass_free(rid: RID) -> void:
    var grass: Grass = _grasses.get(rid)
    if not grass:
        return
    _destroy_grid(grass)
    var data: Object = instance_from_id(grass.maps_data_id) if grass.maps_data_id else null
    if data:
        data.maps_changed.disconnect(_on_terrain_maps_changed)
    _grasses.erase(rid)
    if _grasses.is_empty():
        get_tree().process_frame.disconnect(_follow_camera)


func grass_set_scenario(rid: RID, scenario: RID) -> void:
    var grass: Grass = _grasses.get(rid)
    grass.scenario = scenario
    for instance: RID in grass.instances:
        RenderingServer.instance_set_scenario(instance, scenario)


## The Terrain3D the blades grow on (its maps placing them, its textures choosing where); its maps
## made again - regions streamed in or out - are read again at once
func grass_set_terrain(rid: RID, terrain: Node3D) -> void:
    var grass: Grass = _grasses.get(rid)
    var previous: Object = instance_from_id(grass.maps_data_id) if grass.maps_data_id else null
    if previous:
        previous.maps_changed.disconnect(_on_terrain_maps_changed)
    grass.terrain_id = terrain.get_instance_id() if terrain else 0
    grass.maps_data_id = terrain.data.get_instance_id() if terrain and terrain.data else 0
    # one connection a terrain's data, counted by the grasses on it (a signal's connection is its
    # method's, whatever is bound to it)
    if grass.maps_data_id:
        terrain.data.maps_changed.connect(_on_terrain_maps_changed, CONNECT_REFERENCE_COUNTED)
    _create_grid(grass)


## A terrain's texture arrays and region map are new ones: the process materials of the grasses
## placed are told them
func _on_terrain_maps_changed() -> void:
    for grass: Grass in _grasses.values():
        if not grass.particles.is_empty():
            _set_process_parameters(grass, grass.last_position.snapped(Vector3.ONE))


## The blades' settings (BiomesGrass.get_config()); the grid is made again
func grass_configure(rid: RID, config: Dictionary) -> void:
    var grass: Grass = _grasses.get(rid)
    grass.config = config
    _create_grid(grass)


func _create_grid(grass: Grass) -> void:
    _destroy_grid(grass)
    var terrain: Node3D = instance_from_id(grass.terrain_id) as Node3D if grass.terrain_id else null
    var config: Dictionary = grass.config
    if not terrain or not terrain.data or config.is_empty() or not config["process_material"] or not config["mesh"]:
        return
    var spacing: float = config["instance_spacing"]
    var rows: int = config["rows"]
    var half_grid: int = config["grid_width"] / 2
    var height_range: Vector2 = terrain.data.get_height_range()
    var aabb: AABB = AABB(Vector3(-config["cell_width"] * 0.5, height_range.y, -config["cell_width"] * 0.5),
            Vector3(config["cell_width"], height_range.x - height_range.y, config["cell_width"]))
    var fixed_fps: int = config["process_fixed_fps"]
    for x in range(-half_grid, half_grid + 1):
        for z in range(-half_grid, half_grid + 1):
            grass.offsets.append(Vector3(float(x * rows) * spacing, 0.0, float(z * rows) * spacing))
            var particles: RID = RenderingServer.particles_create()
            RenderingServer.particles_set_mode(particles, RenderingServer.PARTICLES_MODE_3D)
            RenderingServer.particles_set_amount(particles, config["amount"])
            RenderingServer.particles_set_lifetime(particles, PARTICLES_LIFETIME)
            RenderingServer.particles_set_explosiveness_ratio(particles, 1.0)
            RenderingServer.particles_set_process_material(particles, config["process_material"].get_rid())
            RenderingServer.particles_set_draw_passes(particles, 1)
            RenderingServer.particles_set_draw_pass_mesh(particles, 0, config["mesh"].get_rid())
            RenderingServer.particles_set_custom_aabb(particles, aabb)
            RenderingServer.particles_set_fixed_fps(particles, fixed_fps)
            # prevents minor grid alignment errors when the camera moves very fast
            RenderingServer.particles_set_pre_process_time(particles, 1.0 / float(fixed_fps))
            RenderingServer.particles_set_emitting(particles, true)
            var instance: RID = RenderingServer.instance_create2(particles, grass.scenario)
            RenderingServer.instance_geometry_set_cast_shadows_setting(instance, config["shadow_mode"])
            if config["mesh_material_override"]:
                RenderingServer.instance_geometry_set_material_override(instance, config["mesh_material_override"].get_rid())
            grass.particles.append(particles)
            grass.instances.append(instance)
    grass.last_position = Vector3.INF


func _destroy_grid(grass: Grass) -> void:
    for instance: RID in grass.instances:
        RenderingServer.free_rid(instance)
    for particles: RID in grass.particles:
        RenderingServer.free_rid(particles)
    grass.instances.clear()
    grass.particles.clear()
    grass.offsets.clear()


## Every frame while there is grass: a grid the camera moved a metre away from is placed around it
## again, and the process material told the terrain's maps (Terrain3D's particle example)
func _follow_camera() -> void:
    var camera: Camera3D = _get_camera()
    if not camera:
        return
    for grass: Grass in _grasses.values():
        if grass.particles.is_empty() or grass.last_position.distance_squared_to(camera.global_position) <= 1.0:
            continue
        grass.last_position = camera.global_position
        var config: Dictionary = grass.config
        var spacing: float = config["instance_spacing"]
        var position: Vector3 = camera.global_position.snapped(Vector3.ONE)
        for index: int in grass.particles.size():
            var snap: Vector3 = Vector3(position.x, 0.0, position.z).snapped(Vector3.ONE) + grass.offsets[index]
            var cell: Transform3D = Transform3D(Basis.IDENTITY, (snap / spacing).round() * spacing)
            RenderingServer.instance_set_transform(grass.instances[index], cell)
            RenderingServer.particles_set_emission_transform(grass.particles[index], cell)
            RenderingServer.particles_restart(grass.particles[index])
        _set_process_parameters(grass, position)


func _set_process_parameters(grass: Grass, camera_position: Vector3) -> void:
    var terrain: Node3D = instance_from_id(grass.terrain_id) as Node3D
    if not terrain:
        return
    var config: Dictionary = grass.config
    var process: RID = config["process_material"].get_rid()
    RenderingServer.material_set_param(process, "camera_position", camera_position)
    RenderingServer.material_set_param(process, "_background_mode", terrain.material.world_background)
    RenderingServer.material_set_param(process, "_vertex_spacing", terrain.vertex_spacing)
    RenderingServer.material_set_param(process, "_vertex_density", 1.0 / terrain.vertex_spacing)
    RenderingServer.material_set_param(process, "_region_size", terrain.region_size)
    RenderingServer.material_set_param(process, "_region_texel_size", 1.0 / terrain.region_size)
    RenderingServer.material_set_param(process, "_region_map_size", REGION_MAP_SIZE)
    RenderingServer.material_set_param(process, "_region_map", terrain.data.get_region_map())
    RenderingServer.material_set_param(process, "_region_map_origin", terrain.data.get_region_map_origin())
    RenderingServer.material_set_param(process, "_region_locations", terrain.data.get_region_locations())
    RenderingServer.material_set_param(process, "_height_maps", terrain.data.get_height_maps_rid())
    RenderingServer.material_set_param(process, "_control_maps", terrain.data.get_control_maps_rid())
    RenderingServer.material_set_param(process, "_color_maps", terrain.data.get_color_maps_rid())
    RenderingServer.material_set_param(process, "instance_spacing", config["instance_spacing"])
    RenderingServer.material_set_param(process, "instance_rows", config["rows"])
    RenderingServer.material_set_param(process, "max_dist", config["min_draw_distance"])
    # the textures grown on, read as a scatter reads them (_terrain_texture_at())
    RenderingServer.material_set_param(process, "allowed_ids", config["terrain_textures"])
    RenderingServer.material_set_param(process, "autoshader_mode", config["terrain_autoshader"])
    RenderingServer.material_set_param(process, "use_overlay", config["terrain_overlay"])
    RenderingServer.material_set_param(process, "_auto_shader", terrain.material.get_auto_shader())
    for parameter: Array in [["auto_slope", AUTO_SLOPE_DEFAULT], ["auto_height_reduction", AUTO_HEIGHT_REDUCTION_DEFAULT],
            ["auto_base_texture", AUTO_BASE_TEXTURE_DEFAULT], ["auto_overlay_texture", AUTO_OVERLAY_TEXTURE_DEFAULT]]:
        RenderingServer.material_set_param(process, "_" + parameter[0], _material_param(terrain, parameter[0], parameter[1]))


func scatter_create() -> RID:
    var rid: RID = rid_from_int64(rid_allocate_id())
    _scatters[rid] = Scatter.new()
    return rid


func scatter_free(rid: RID) -> void:
    var scatter: Scatter = _scatters.get(rid)
    if not scatter:
        return
    _wait_for_tasks(scatter)
    for coords: Vector2i in scatter.chunks.keys():
        _drop_chunk(scatter, coords)
    _scatters.erase(rid)


## The world the biome is drawn in, and the physics space its ray finds the surface in (without a terrain)
func scatter_set_scenario(rid: RID, scenario: RID, space: RID) -> void:
    var scatter: Scatter = _scatters.get(rid)
    scatter.scenario = scenario
    scatter.space = space
    for chunk: Dictionary in scatter.chunks.values():
        for instance: RID in chunk["instances"]:
            RenderingServer.instance_set_scenario(instance, scenario)


## Where the biome's area is centred: its node's global transform
func scatter_set_transform(rid: RID, transform: Transform3D) -> void:
    var scatter: Scatter = _scatters.get(rid)
    if scatter.transform == transform:
        return
    scatter.transform = transform
    _clear(scatter)


## The Terrain3D the biome stands on and grows on the textures of; null: the physics ray
func scatter_set_terrain(rid: RID, terrain: Node3D) -> void:
    var scatter: Scatter = _scatters.get(rid)
    scatter.terrain_id = terrain.get_instance_id() if terrain else 0
    _clear(scatter)


## The biome's settings (Biomes.get_config()) and its mask image (null: none); what was grown goes
## and grows again
func scatter_configure(rid: RID, config: Dictionary, mask: Image) -> void:
    var scatter: Scatter = _scatters.get(rid)
    # the worker threads read the settings: they are done before the settings change
    _clear(scatter)
    scatter.config = config
    scatter.mask = mask
    scatter.entries = _resolve_entries(config["entries"])


## The chunks under [param area] (global; the terrain painted there) grow again
func scatter_drop_area(rid: RID, area: AABB) -> void:
    var scatter: Scatter = _scatters.get(rid)
    _wait_for_tasks(scatter)
    var size: float = scatter.config.get("chunk_size", 16.0)
    var inverse: Transform3D = scatter.transform.affine_inverse()
    var start: Vector3 = inverse * area.position
    var end: Vector3 = inverse * area.end
    for x in range(floori(minf(start.x, end.x) / size), floori(maxf(start.x, end.x) / size) + 1):
        for z in range(floori(minf(start.z, end.z) / size), floori(maxf(start.z, end.z) / size) + 1):
            _drop_chunk(scatter, Vector2i(x, z))


## How many instances the biome draws now (its chunks built), and how many chunks
func scatter_get_statistics(rid: RID) -> Dictionary:
    var scatter: Scatter = _scatters.get(rid)
    var count: int = 0
    for chunk: Dictionary in scatter.chunks.values():
        count += chunk["count"]
    return {"chunks": scatter.chunks.size(), "instances": count, "pending": scatter.tasks.size()}


## Every chunk goes and grows again as the camera needs it
func _clear(scatter: Scatter) -> void:
    _wait_for_tasks(scatter)
    scatter.generation += 1
    for coords: Vector2i in scatter.chunks.keys():
        _drop_chunk(scatter, coords)


func _wait_for_tasks(scatter: Scatter) -> void:
    for coords: Vector2i in scatter.tasks:
        WorkerThreadPool.wait_for_task_completion(scatter.tasks[coords])
    scatter.tasks.clear()
    scatter.mutex.lock()
    scatter.points.clear()
    scatter.mutex.unlock()


func _drop_chunk(scatter: Scatter, coords: Vector2i) -> void:
    var chunk: Dictionary = scatter.chunks.get(coords, {})
    for instance: RID in chunk.get("instances", []):
        RenderingServer.free_rid(instance)
    for multimesh: RID in chunk.get("multimeshes", []):
        RenderingServer.free_rid(multimesh)
    scatter.chunks.erase(coords)


## The camera the biomes grow around: the editor's 3D view in the editor, the viewport's in the game
func _get_camera() -> Camera3D:
    if Engine.is_editor_hint():
        # through Engine: an exported game has no EditorInterface and the script would not parse there
        var editor_viewport: SubViewport = Engine.get_singleton("EditorInterface").get_editor_viewport_3d(0)
        return editor_viewport.get_camera_3d() if editor_viewport else null
    return get_viewport().get_camera_3d()


## The timer's work: every biome's chunks planned around the camera, the ready ones built, the far
## ones dropped, the density of the near ones set
func _stream() -> void:
    var camera: Camera3D = _get_camera()
    if not camera or _scatters.is_empty():
        return
    for scatter: Scatter in _scatters.values():
        if scatter.entries.is_empty() or not scatter.config.get("streaming_enabled", true) or not scatter.scenario.is_valid():
            continue
        if not scatter.high_quality == _high_quality:
            scatter.high_quality = _high_quality
            _apply_shadows(scatter)
        _stream_scatter(scatter, camera.global_position)


func _stream_scatter(scatter: Scatter, camera_position: Vector3) -> void:
    var config: Dictionary = scatter.config
    var size: float = config["chunk_size"]
    var camera_local: Vector3 = scatter.transform.affine_inverse() * camera_position
    var camera_chunk: Vector2i = Vector2i(floori(camera_local.x / size), floori(camera_local.z / size))
    var distance: float = config["max_generation_distance"]
    if config["follow_draw_distance"] and Engine.has_singleton(&"SceneryStreamingServer"):
        distance = minf(Engine.get_singleton(&"SceneryStreamingServer").streaming_get_draw_distance(),
                config["max_generation_distance_cap"])
    var radius: int = ceili(distance / size)
    # no chunk outside area_size
    var half_area: Vector2 = config["area_size"] * 0.5
    var area_min: Vector2i = Vector2i(floori(-half_area.x / size), floori(-half_area.y / size))
    var area_max: Vector2i = Vector2i(ceili(half_area.x / size) - 1, ceili(half_area.y / size) - 1)
    var needed: Dictionary = {}
    var order: Array[Vector2i] = []
    for x in range(maxi(camera_chunk.x - radius, area_min.x), mini(camera_chunk.x + radius, area_max.x) + 1):
        for z in range(maxi(camera_chunk.y - radius, area_min.y), mini(camera_chunk.y + radius, area_max.y) + 1):
            var coords: Vector2i = Vector2i(x, z)
            var center: Vector3 = _chunk_center(coords, size)
            if Vector2(camera_local.x, camera_local.z).distance_to(Vector2(center.x, center.z)) <= distance:
                needed[coords] = true
                order.append(coords)
    order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return (a - camera_chunk).length_squared() < (b - camera_chunk).length_squared())
    for coords: Vector2i in scatter.chunks.keys():
        if not needed.has(coords):
            _drop_chunk(scatter, coords)
    # a task of a chunk no longer needed is let go of once done, with its points
    for coords: Vector2i in scatter.tasks.keys():
        if not needed.has(coords) and WorkerThreadPool.is_task_completed(scatter.tasks[coords]):
            WorkerThreadPool.wait_for_task_completion(scatter.tasks[coords])
            scatter.tasks.erase(coords)
            scatter.mutex.lock()
            scatter.points.erase(coords)
            scatter.mutex.unlock()

    var built: int = 0
    for coords: Vector2i in order:
        if scatter.chunks.has(coords):
            continue
        if not scatter.tasks.has(coords):
            var generation: int = scatter.generation
            scatter.tasks[coords] = WorkerThreadPool.add_task(_generate_points.bind(scatter, coords, generation))
            continue
        if built >= config["chunks_per_frame"] * STREAM_FRAMES or not WorkerThreadPool.is_task_completed(scatter.tasks[coords]):
            continue
        WorkerThreadPool.wait_for_task_completion(scatter.tasks[coords])
        scatter.tasks.erase(coords)
        scatter.mutex.lock()
        var points: Array = scatter.points.get(coords, [])
        scatter.points.erase(coords)
        scatter.mutex.unlock()
        _build_chunk(scatter, coords, points)
        built += 1
    if config["density_lod_enabled"]:
        _apply_density(scatter, camera_local)


## On a worker thread: the candidate points of a chunk - one per cell of the spacing, jittered by a
## hash of the cell, kept by the mask's density, given an entry, a scale and a turn
func _generate_points(scatter: Scatter, coords: Vector2i, generation: int) -> void:
    var config: Dictionary = scatter.config
    var seed_value: int = config["seed"]
    var size: float = config["chunk_size"]
    var area_size: Vector2 = config["area_size"]
    var chunk_min: Vector2 = Vector2(coords) * size
    var chunk_max: Vector2 = chunk_min + Vector2(size, size)
    var half_area: Vector2 = area_size * 0.5
    var spacing: float = maxf(config["average_spacing"], 0.1)
    if config["max_instances"] > 0:
        spacing = maxf(spacing, sqrt(maxf(area_size.x * area_size.y, 0.0001) / float(config["max_instances"])))
    var points: Array = []
    for cell_x in range(floori(chunk_min.x / spacing), ceili(chunk_max.x / spacing)):
        for cell_z in range(floori(chunk_min.y / spacing), ceili(chunk_max.y / spacing)):
            var x: float = (float(cell_x) + _hash01(seed_value, cell_x, cell_z, 11)) * spacing
            var z: float = (float(cell_z) + _hash01(seed_value, cell_x, cell_z, 17)) * spacing
            if x < chunk_min.x or x >= chunk_max.x or z < chunk_min.y or z >= chunk_max.y:
                continue
            if x < -half_area.x or x > half_area.x or z < -half_area.y or z > half_area.y:
                continue
            var density: float = _mask_density(scatter, x, z)
            if density <= 0.0 or _hash01(seed_value, cell_x, cell_z, 7) > density:
                continue
            var entry: Dictionary = _pick_entry(scatter.entries, seed_value, cell_x, cell_z)
            if entry.is_empty():
                continue
            var scale_min: Vector3 = entry["scale_min"]
            var scale_max: Vector3 = entry["scale_max"]
            var scale: Vector3 = Vector3(
                lerpf(minf(scale_min.x, scale_max.x), maxf(scale_min.x, scale_max.x), _hash01(seed_value, cell_x, cell_z, 23)),
                lerpf(minf(scale_min.y, scale_max.y), maxf(scale_min.y, scale_max.y), _hash01(seed_value, cell_x, cell_z, 29)),
                lerpf(minf(scale_min.z, scale_max.z), maxf(scale_min.z, scale_max.z), _hash01(seed_value, cell_x, cell_z, 31)))
            points.append({"position": Vector3(x, 0.0, z), "scale": scale,
                    "yaw": TAU * _hash01(seed_value, cell_x, cell_z, 37), "entry": entry,
                    "priority": _hash01(seed_value, cell_x, cell_z, 53)})
    scatter.mutex.lock()
    if generation == scatter.generation:
        scatter.points[coords] = points
    scatter.mutex.unlock()


## On the main thread: the chunk's points stood on the terrain (where it grows on the biome's
## texture) and drawn - per entry and model part a near MultiMesh, and a billboard one past the
## entry's billboard_lod_distance
func _build_chunk(scatter: Scatter, coords: Vector2i, points: Array) -> void:
    var config: Dictionary = scatter.config
    var size: float = config["chunk_size"]
    var center: Vector3 = _chunk_center(coords, size)
    var terrain: Node3D = instance_from_id(scatter.terrain_id) as Node3D if scatter.terrain_id else null
    var state: PhysicsDirectSpaceState3D = PhysicsServer3D.space_get_direct_state(scatter.space) \
            if not terrain and scatter.space.is_valid() else null
    # entry index -> [transforms (local), priorities]
    var buckets: Dictionary = {}
    for point: Dictionary in points:
        var local: Vector3 = point["position"]
        var global: Vector3 = scatter.transform * local
        if terrain and not config["terrain_texture"] == TERRAIN_TEXTURE_ANYWHERE \
                and not _terrain_texture_at(terrain, config, global) == config["terrain_texture"]:
            continue
        var surface: Variant = _surface_at(scatter, terrain, state, local, global)
        if surface == null:
            continue
        var entry: Dictionary = point["entry"]
        if not buckets.has(entry["index"]):
            buckets[entry["index"]] = [entry, [], []]
        buckets[entry["index"]][1].append(Transform3D(
                Basis.IDENTITY.rotated(Vector3.UP, point["yaw"]).scaled(point["scale"]), surface))
        buckets[entry["index"]][2].append(point["priority"])
    var chunk: Dictionary = {"multimeshes": [], "instances": [], "lods": [], "count": 0, "visible": -1, "center": center}
    var chunk_transform: Transform3D = scatter.transform * Transform3D(Basis.IDENTITY, center)
    for bucket: Array in buckets.values():
        var entry: Dictionary = bucket[0]
        # the instances in the order the density LOD drops them: the highest priority last
        var order: Array = range(bucket[1].size())
        order.sort_custom(func(a: int, b: int) -> bool: return bucket[2][a] < bucket[2][b])
        var transforms: Array[Transform3D] = []
        for index: int in order:
            transforms.append(bucket[1][index])
        var lod: float = entry["billboard_lod_distance"]
        var billboards: Array = entry["billboard_parts"]
        _add_multimeshes(scatter, chunk, chunk_transform, entry["main_parts"], transforms, center,
                0.0, lod if billboards and lod > 0.0 else 0.0)
        if billboards:
            _add_multimeshes(scatter, chunk, chunk_transform, billboards, transforms, center, lod if lod > 0.0 else 0.0, 0.0)
        chunk["count"] += transforms.size()
    scatter.chunks[coords] = chunk


## A MultiMesh and its instance per part, the transforms relative to the chunk's centre, drawn from
## [param range_begin] to [param range_end] (0: no limit)
func _add_multimeshes(scatter: Scatter, chunk: Dictionary, chunk_transform: Transform3D, parts: Array,
        transforms: Array[Transform3D], center: Vector3, range_begin: float, range_end: float) -> void:
    for part: Dictionary in parts:
        var mesh: Mesh = part["mesh"]
        if not mesh:
            continue
        var part_transform: Transform3D = part["transform"]
        var buffer: PackedFloat32Array = PackedFloat32Array()
        buffer.resize(transforms.size() * TRANSFORM_FLOATS)
        for index: int in transforms.size():
            var t: Transform3D = transforms[index] * part_transform
            t.origin -= center
            var offset: int = index * TRANSFORM_FLOATS
            # RenderingServer's MultiMesh buffer: the 3x4 matrix by rows
            buffer[offset] = t.basis.x.x
            buffer[offset + 1] = t.basis.y.x
            buffer[offset + 2] = t.basis.z.x
            buffer[offset + 3] = t.origin.x
            buffer[offset + 4] = t.basis.x.y
            buffer[offset + 5] = t.basis.y.y
            buffer[offset + 6] = t.basis.z.y
            buffer[offset + 7] = t.origin.y
            buffer[offset + 8] = t.basis.x.z
            buffer[offset + 9] = t.basis.y.z
            buffer[offset + 10] = t.basis.z.z
            buffer[offset + 11] = t.origin.z
        var multimesh: RID = RenderingServer.multimesh_create()
        RenderingServer.multimesh_set_mesh(multimesh, mesh.get_rid())
        RenderingServer.multimesh_allocate_data(multimesh, transforms.size(), RenderingServer.MULTIMESH_TRANSFORM_3D)
        RenderingServer.multimesh_set_buffer(multimesh, buffer)
        var instance: RID = RenderingServer.instance_create2(multimesh, scatter.scenario)
        RenderingServer.instance_set_transform(instance, chunk_transform)
        RenderingServer.instance_geometry_set_cast_shadows_setting(instance, _shadows(scatter))
        if range_begin > 0.0 or range_end > 0.0:
            RenderingServer.instance_geometry_set_visibility_range(instance, range_begin, range_end, 0.0, 0.0,
                    RenderingServer.VISIBILITY_RANGE_FADE_DISABLED)
        chunk["multimeshes"].append(multimesh)
        chunk["instances"].append(instance)
        chunk["lods"].append(transforms.size())


func _shadows(scatter: Scatter) -> RenderingServer.ShadowCastingSetting:
    return scatter.config["shadow_casting"] as RenderingServer.ShadowCastingSetting if scatter.high_quality \
            else RenderingServer.SHADOW_CASTING_SETTING_OFF


func _apply_shadows(scatter: Scatter) -> void:
    for chunk: Dictionary in scatter.chunks.values():
        for instance: RID in chunk["instances"]:
            RenderingServer.instance_geometry_set_cast_shadows_setting(instance, _shadows(scatter))


## The density LOD: a chunk draws a share of its instances by its distance from the camera
func _apply_density(scatter: Scatter, camera_local: Vector3) -> void:
    var config: Dictionary = scatter.config
    for chunk: Dictionary in scatter.chunks.values():
        var fraction: float = _density_fraction(config, camera_local.distance_to(chunk["center"]))
        var visible: int = roundi(fraction * 1000.0)
        if visible == chunk["visible"]:
            continue
        chunk["visible"] = visible
        for index: int in chunk["multimeshes"].size():
            var full: int = chunk["lods"][index]
            RenderingServer.multimesh_set_visible_instances(chunk["multimeshes"][index],
                    clampi(roundi(float(full) * fraction), 0, full))


static func _density_fraction(config: Dictionary, distance: float) -> float:
    var min_fraction: float = clampf(config["density_lod_min_fraction"], 0.0, 1.0)
    var start: float = config["density_lod_start_distance"]
    var end: float = config["density_lod_end_distance"]
    if end <= start:
        return min_fraction if distance > start else 1.0
    if distance <= start:
        return 1.0
    if distance >= end:
        return min_fraction
    var t: float = inverse_lerp(start, end, distance)
    return lerpf(1.0, min_fraction, t * t * (3.0 - 2.0 * t))


## The point [param local] stood on the surface, local to the biome; null where there is none
func _surface_at(scatter: Scatter, terrain: Node3D, state: PhysicsDirectSpaceState3D, local: Vector3, global: Vector3) -> Variant:
    if terrain:
        var height: float = terrain.data.get_height(global)
        if is_nan(height):
            return null
        return scatter.transform.affine_inverse() * Vector3(global.x, height, global.z)
    if not state:
        return local
    var config: Dictionary = scatter.config
    var direction: Vector3 = config["ray_direction"].normalized() if not config["ray_direction"].is_zero_approx() else Vector3.DOWN
    var start: Vector3 = scatter.transform * (local - direction * config["ray_start_offset"])
    var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
            start, start + direction * config["ray_length"], config["collision_mask"])
    query.collide_with_areas = false
    var hit: Dictionary = state.intersect_ray(query)
    return scatter.transform.affine_inverse() * hit["position"] if hit else null


## The terrain's texture at [param global] as the biome reads it (terrain_autoshader,
## terrain_overlay), as Terrain3D's shader picks it
static func _terrain_texture_at(terrain: Node3D, config: Dictionary, global: Vector3) -> int:
    var data: Object = terrain.data
    var base: int = data.get_control_base_id(global)
    var overlay: int = data.get_control_overlay_id(global)
    var blend: float = data.get_control_blend(global)
    if data.get_control_auto(global):
        if config["terrain_autoshader"] == TerrainAutoshader.NOTHING:
            return TERRAIN_TEXTURE_ANYWHERE
        if config["terrain_autoshader"] == TerrainAutoshader.AUTOSHADER_TEXTURE and terrain.material.get_auto_shader():
            base = _material_param(terrain, "auto_base_texture", AUTO_BASE_TEXTURE_DEFAULT)
            overlay = _material_param(terrain, "auto_overlay_texture", AUTO_OVERLAY_TEXTURE_DEFAULT)
            # Terrain3D's shader: lightweight.gdshader:258
            blend = clampf(_material_param(terrain, "auto_slope", AUTO_SLOPE_DEFAULT) * 2.0
                    * (data.get_normal(global).y - 1.0) + 1.0
                    - _material_param(terrain, "auto_height_reduction", AUTO_HEIGHT_REDUCTION_DEFAULT) * 0.01
                    * data.get_height(global), 0.0, 1.0)
    return overlay if config["terrain_overlay"] and blend >= OVERLAY_BLEND_SHOWN else base


static func _material_param(terrain: Node3D, name: String, default: Variant) -> Variant:
    var value: Variant = terrain.material.get_shader_param(name)
    return default if value == null else value


## The mask's density at a point of the biome's area: 1 without a mask, 0 outside it
static func _mask_density(scatter: Scatter, x: float, z: float) -> float:
    var config: Dictionary = scatter.config
    if not config["mask_enabled"] or not scatter.mask:
        return 1.0
    var area_size: Vector2 = config["area_size"]
    var uv: Vector2 = Vector2(x / area_size.x + 0.5, z / area_size.y + 0.5)
    if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
        return 0.0
    var image: Image = scatter.mask
    var color: Color = image.get_pixel(clampi(floori(uv.x * image.get_width()), 0, image.get_width() - 1),
            clampi(floori(uv.y * image.get_height()), 0, image.get_height() - 1))
    var sample: float = mask_channel_value(color, config["mask_channel"])
    var adjusted: float = clampf(1.0 - sample if config["mask_inverse"] else sample, 0.0, 1.0)
    var threshold: float = config["mask_threshold"]
    if not config["mask_affects_density"]:
        return 1.0 if adjusted >= threshold else 0.0
    return 0.0 if adjusted <= threshold else inverse_lerp(threshold, 1.0, adjusted)


static func mask_channel_value(color: Color, channel: int) -> float:
    match channel:
        MaskChannel.GREEN:
            return color.g
        MaskChannel.BLUE:
            return color.b
        MaskChannel.ALPHA:
            return color.a
        MaskChannel.LUMINANCE:
            return color.get_luminance()
    return color.r


static func _pick_entry(entries: Array[Dictionary], seed_value: int, cell_x: int, cell_z: int) -> Dictionary:
    var total: float = 0.0
    for entry: Dictionary in entries:
        total += float(entry["probability"])
    if total <= 0.0:
        return {}
    var pick: float = _hash01(seed_value, cell_x, cell_z, 41) * total
    var cumulative: float = 0.0
    for entry: Dictionary in entries:
        cumulative += float(entry["probability"])
        if pick <= cumulative:
            return entry
    return entries.back()


static func _chunk_center(coords: Vector2i, size: float) -> Vector3:
    return Vector3((float(coords.x) + 0.5) * size, 0.0, (float(coords.y) + 0.5) * size)


static func _hash01(a: int, b: int, c: int, salt: int) -> float:
    var value: int = (a ^ (b * 374761393) ^ (c * 668265263) ^ (salt * 2246822519)) & HASH_MASK
    value = (value ^ (value >> 13)) & HASH_MASK
    value = (value * 1274126177) & HASH_MASK
    value = (value ^ (value >> 16)) & HASH_MASK
    return float(value) / float(HASH_MASK)


## The entries made drawable: their models' mesh parts (with the materials of their instances) and
## billboard parts (billboard.gdshader), the billboards' materials kept on the entry for its brightness
func _resolve_entries(entries: Array) -> Array[Dictionary]:
    var resolved: Array[Dictionary] = []
    var billboard_cache: Dictionary = {}
    for index: int in entries.size():
        var entry: BiomeScatterEntry = entries[index]
        if not entry:
            continue
        var main_parts: Array[Dictionary] = _mesh_parts(entry.mesh_scene, entry.mesh, false, billboard_cache)
        if main_parts.is_empty() or entry.probability <= 0.0:
            continue
        var billboard_parts: Array[Dictionary] = _mesh_parts(entry.billboard_scene, entry.billboard_mesh, true, billboard_cache)
        entry.billboard_materials.clear()
        for part: Dictionary in billboard_parts:
            var part_mesh: Mesh = part["mesh"]
            for surface: int in part_mesh.get_surface_count():
                var material: ShaderMaterial = part_mesh.surface_get_material(surface) as ShaderMaterial
                if material and material.shader == BILLBOARD_SHADER:
                    material.set_shader_parameter("brightness", entry.billboard_brightness)
                    entry.billboard_materials.append(material)
        resolved.append({"index": index, "main_parts": main_parts, "billboard_parts": billboard_parts,
                "probability": entry.probability, "billboard_lod_distance": maxf(entry.billboard_lod_distance, 0.0),
                "scale_min": entry.scale_min, "scale_max": entry.scale_max})
    return resolved


func _mesh_parts(scene: PackedScene, fallback: Mesh, billboard: bool, cache: Dictionary) -> Array[Dictionary]:
    var parts: Array[Dictionary] = []
    var instance: Node = scene.instantiate() if scene else null
    if instance:
        _collect_mesh_parts(instance, Transform3D.IDENTITY, billboard, parts, cache)
        instance.free()
    if parts.is_empty() and fallback:
        parts.append({"mesh": _billboard_mesh(fallback, cache) if billboard else fallback, "transform": Transform3D.IDENTITY})
    return parts


func _collect_mesh_parts(node: Node, parent: Transform3D, billboard: bool, parts: Array[Dictionary], cache: Dictionary) -> void:
    var local: Transform3D = parent * (node as Node3D).transform if node is Node3D else parent
    var mesh_instance: MeshInstance3D = node as MeshInstance3D
    if mesh_instance and mesh_instance.mesh:
        var mesh: Mesh = mesh_instance.mesh.duplicate(true) as Mesh
        for surface: int in mesh.get_surface_count():
            var material: Material = mesh_instance.get_active_material(surface)
            if material:
                mesh.surface_set_material(surface, _billboard_material(material) if billboard and material is BaseMaterial3D else material)
        parts.append({"mesh": _billboard_mesh(mesh, cache) if billboard else mesh, "transform": local})
    for child: Node in node.get_children():
        _collect_mesh_parts(child, local, billboard, parts, cache)


func _billboard_mesh(source: Mesh, cache: Dictionary) -> Mesh:
    if cache.has(source.get_instance_id()):
        return cache[source.get_instance_id()]
    var mesh: Mesh = source.duplicate(true) as Mesh
    for surface: int in mesh.get_surface_count():
        var material: Material = mesh.surface_get_material(surface)
        if not material or material is BaseMaterial3D:
            mesh.surface_set_material(surface, _billboard_material(material))
    cache[source.get_instance_id()] = mesh
    return mesh


## The far LOD's material: billboard.gdshader with [param source]'s texture and colour (a
## BaseMaterial3D from the billboard generator; null gives a white one). BaseMaterial3D's own
## BILLBOARD_FIXED_Y lit the quad by a normal following the camera (see the shader).
static func _billboard_material(source: Material) -> ShaderMaterial:
    var material: ShaderMaterial = ShaderMaterial.new()
    material.shader = BILLBOARD_SHADER
    var base: BaseMaterial3D = source as BaseMaterial3D
    if base:
        material.resource_name = base.resource_name
        material.set_shader_parameter("albedo_texture", base.albedo_texture)
        material.set_shader_parameter("albedo_color", base.albedo_color)
    return material
