@tool
extends Node
## BiomesServer (autoload): grows the biomes. A node describes a kind of biome and hands it to the
## server; the server grows it around the camera, with RenderingServer's objects alone - no nodes:
## - a scatter (Biomes: models - trees, flowers - over an area, on a texture of its terrain;
##   scatter_create(), scatter_configure()): a chunk at a time, worked out on the worker threads -
##   its points, on a terrain stood on it and their MultiMeshes' buffers too, from the maps of its
##   regions taken for the task (_terrain_job()) - and drawn as MultiMeshes (a near one and a
##   billboard one per model part) on the main thread; the chunks are planned on a timer
##   (STREAM_INTERVAL), never per frame. On a terrain, its entries all with billboards, the
##   billboards are drawn by the GPU instead (_far_create(): particles placing the trees as the CPU
##   does), and the CPU grows only the chunks whose models are drawn: what is drawn where is decided
##   by a chunk's middle's distance from the camera on both (_apply_visibility(),
##   billboard_particles.gdshader). Where a forest's
##   trees end its canopy baked with the world (BiomesFarCanopy) shows: its layer's distance is
##   CANOPY_BEGIN_PARAMETER;
## - grass (BiomesGrass: blades - grass, grain - on textures of its terrain; grass_create(),
##   grass_configure()): a grid of GPU particles placed by the process material from the terrain's
##   maps, moved after the camera - the one thing looked at every frame, while there is grass.

const BILLBOARD_SHADER: Shader = preload("./billboard.gdshader")
## A layer's billboards on the GPU (the far trees): placed by the particles' process shader, drawn by
## the draw pass's
const BILLBOARDS_SHADER: Shader = preload("./billboards.gdshader")
const BILLBOARD_PARTICLES_SHADER: Shader = preload("./billboard_particles.gdshader")
## The far trees' entries at most (the shaders' ENTRIES_MAX)
const FAR_ENTRIES_MAX: int = 8
## The far trees' grid moves after the camera by this [m], restarted then
const FAR_ANCHOR_STEP: float = 64.0
## The far trees' bounds over the terrain's highest point, for the tallest tree [m]
const FAR_TREE_HEIGHT_MAX: float = 60.0
## How often the camera is looked at and the chunks planned [s]
const STREAM_INTERVAL: float = 0.1
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
## Terrain3D's control map (terrain_3d_util.h): an autoshaded and a hole vertex's bits
const CONTROL_AUTO: int = 0x1
const CONTROL_HOLE: int = 0x4
## Terrain3D's control map's base and overlay texture ids and blend: their bits' place and width
const CONTROL_BASE_SHIFT: int = 27
const CONTROL_OVERLAY_SHIFT: int = 22
const CONTROL_ID_MASK: int = 0x1F
const CONTROL_BLEND_SHIFT: int = 14
const CONTROL_BLEND_MASK: int = 0xFF
const HASH_MASK: int = 0xFFFFFFFF
## The chunks a biome has the worker threads work out at once, the nearest first
const CHUNK_TASKS: int = 16
## The main thread's time a frame for making the chunks the worker threads have done [us]
const CHUNK_MAKE_BUDGET_USEC: int = 1000
## Floats of an instance's transform in a MultiMesh buffer (3x4)
const TRANSFORM_FLOATS: int = 12
## Grass: a particle lives this long - the grid restarts it whenever it moves [s]
const PARTICLES_LIFETIME: float = 600.0
## Terrain3D's region map, regions along its side
const REGION_MAP_SIZE: int = 32
## The project's global shader parameter that turns the biomes' shadows off when false
const HIGH_QUALITY_PARAMETER: StringName = &"gnd_high_quality_foliage"
## The global shader parameter of the far canopy (BiomesFarCanopy, far_canopy.gdshader): from how far
## it shows - where the trees of the layer with far_canopy end [m]
const CANOPY_BEGIN_PARAMETER: StringName = &"gnd_canopy_begin"

enum MaskChannel { RED, GREEN, BLUE, ALPHA, LUMINANCE }
## A model part's shadow: as the biome's shadow_casting says, none (its entry's shadow_scene casts
## it), or only the shadow (the shadow_scene's parts - hidden when the quality casts none)
enum PartShadow { CAST, NONE, ONLY }
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
    ## The terrain's data whose maps_changed the scatter follows (as Grass.maps_data_id)
    var maps_data_id: int = 0
    ## chunk coords -> {multimeshes: Array[RID], instances: Array[RID], count: int, visible: int,
    ## center: Vector3, missing: bool - points of it stood where the terrain had no region yet}
    var chunks: Dictionary = {}
    ## chunk coords -> WorkerThreadPool task id
    var tasks: Dictionary = {}
    ## chunk coords -> what the worker threads worked out: on a terrain the chunk grown
    ## (_grow_chunk()), without one an Array of its points (_generate_points())
    var points: Dictionary = {}
    var mutex: Mutex = Mutex.new()
    ## Raised by every configuration: a task of an earlier one leaves its points unused
    var generation: int = 0
    ## Raised whenever the terrain's maps change (regions streamed in): a chunk grown on the maps of
    ## before where a region was missing is let go of and grows again
    var terrain_stamp: int = 0
    ## The billboards drawn on the GPU (_far_create()): particles, instance, process, draw (materials),
    ## quad, spacing, reach, distance, anchor (cell); empty while the CPU draws them
    var far: Dictionary = {}
    ## Where the camera was when what is drawn where was decided last (_apply_visibility())
    var view: Vector3 = Vector3.INF
    ## The chunks around the camera's chunk to grow: their offsets from it, nearest first - planned
    ## when the distance or the chunk's size changes (plan: [distance, size]), the same wherever the
    ## camera is - the camera's chunk, and the next offset to look at
    var offsets: Array[Vector2i] = []
    var plan: Array = []
    var center: Vector2i = Vector2i.MAX
    var next: int = 0
    var high_quality: bool = true


var _scatters: Dictionary = {}
## RID -> Grass
var _grasses: Dictionary = {}
var _timer: Timer
var _high_quality: bool = true
## The far canopy's distance set last (CANOPY_BEGIN_PARAMETER)
var _canopy_begin: float = -1.0
## The chunks the worker threads have done, to be made: [scatter, coords, generation] - made a
## frame's CHUNK_MAKE_BUDGET_USEC at a time while there are any (_make_done_chunks())
var _done: Array[Array] = []


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
    # the far canopy's shader reads it: there before any world's far terrain is loaded, in a
    # project that does not declare it
    if not ProjectSettings.has_setting("shader_globals/" + CANOPY_BEGIN_PARAMETER):
        RenderingServer.global_shader_parameter_add(CANOPY_BEGIN_PARAMETER,
                RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
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


## A terrain's texture arrays and region map are new ones - regions streamed in or out: the grasses
## placed are told them and span the heights there are now, and a scatter's chunks stood partly off
## the terrain grow again
func _on_terrain_maps_changed() -> void:
    for grass: Grass in _grasses.values():
        if not grass.particles.is_empty():
            var aabb: AABB = _grass_aabb(grass)
            for particles: RID in grass.particles:
                RenderingServer.particles_set_custom_aabb(particles, aabb)
            _set_process_parameters(grass, grass.last_position.snapped(Vector3.ONE))
    for scatter: Scatter in _scatters.values():
        scatter.terrain_stamp += 1
        # the far trees stand on the maps there are now
        if scatter.far:
            scatter.far["anchor"] = Vector2i.MAX
        for coords: Vector2i in scatter.chunks.keys():
            if scatter.chunks[coords]["missing"]:
                _drop_chunk(scatter, coords)
        scatter.next = 0


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
    var aabb: AABB = _grass_aabb(grass)
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


## A cell of the grass's grid over the heights of its terrain's regions there are now (an empty
## range culls the blades wherever the terrain is)
func _grass_aabb(grass: Grass) -> AABB:
    var terrain: Node3D = instance_from_id(grass.terrain_id) as Node3D
    var cell_width: float = grass.config["cell_width"]
    var height_range: Vector2 = terrain.data.get_height_range()
    return AABB(Vector3(-cell_width * 0.5, height_range.y, -cell_width * 0.5),
            Vector3(cell_width, height_range.x - height_range.y, cell_width))


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
    _set_terrain_maps(process, terrain)
    RenderingServer.material_set_param(process, "_region_texel_size", 1.0 / terrain.region_size)
    RenderingServer.material_set_param(process, "_region_locations", terrain.data.get_region_locations())
    RenderingServer.material_set_param(process, "_color_maps", terrain.data.get_color_maps_rid())
    RenderingServer.material_set_param(process, "instance_spacing", config["instance_spacing"])
    RenderingServer.material_set_param(process, "instance_rows", config["rows"])
    RenderingServer.material_set_param(process, "max_dist", config["min_draw_distance"])
    # the textures grown on, read as a scatter reads them (_terrain_texture_at())
    RenderingServer.material_set_param(process, "allowed_ids", config["terrain_textures"])
    RenderingServer.material_set_param(process, "autoshader_mode", config["terrain_autoshader"])
    RenderingServer.material_set_param(process, "use_overlay", config["terrain_overlay"])


## A particles' process material told [param terrain]'s maps and how its material shows them (the
## grass's and the far trees' shaders read them alike)
static func _set_terrain_maps(process: RID, terrain: Node3D) -> void:
    RenderingServer.material_set_param(process, "_background_mode", terrain.material.world_background)
    RenderingServer.material_set_param(process, "_vertex_spacing", terrain.vertex_spacing)
    RenderingServer.material_set_param(process, "_vertex_density", 1.0 / terrain.vertex_spacing)
    RenderingServer.material_set_param(process, "_region_size", terrain.region_size)
    RenderingServer.material_set_param(process, "_region_map_size", REGION_MAP_SIZE)
    RenderingServer.material_set_param(process, "_region_map", terrain.data.get_region_map())
    RenderingServer.material_set_param(process, "_region_map_origin", terrain.data.get_region_map_origin())
    RenderingServer.material_set_param(process, "_height_maps", terrain.data.get_height_maps_rid())
    RenderingServer.material_set_param(process, "_control_maps", terrain.data.get_control_maps_rid())
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
    var data: Object = instance_from_id(scatter.maps_data_id) if scatter.maps_data_id else null
    if data:
        data.maps_changed.disconnect(_on_terrain_maps_changed)
    _scatters.erase(rid)


## The world the biome is drawn in, and the physics space its ray finds the surface in (without a terrain)
func scatter_set_scenario(rid: RID, scenario: RID, space: RID) -> void:
    var scatter: Scatter = _scatters.get(rid)
    scatter.scenario = scenario
    scatter.space = space
    for chunk: Dictionary in scatter.chunks.values():
        for instance: RID in chunk["instances"]:
            RenderingServer.instance_set_scenario(instance, scenario)
    if scatter.far:
        RenderingServer.instance_set_scenario(scatter.far["instance"], scenario)


## Where the biome's area is centred: its node's global transform
func scatter_set_transform(rid: RID, transform: Transform3D) -> void:
    var scatter: Scatter = _scatters.get(rid)
    if scatter.transform == transform:
        return
    scatter.transform = transform
    _clear(scatter)


## The Terrain3D the biome stands on and grows on the textures of; null: the physics ray. Its maps
## made again - regions streamed in - grow the chunks again that stood partly where it had none
func scatter_set_terrain(rid: RID, terrain: Node3D) -> void:
    var scatter: Scatter = _scatters.get(rid)
    var previous: Object = instance_from_id(scatter.maps_data_id) if scatter.maps_data_id else null
    if previous:
        previous.maps_changed.disconnect(_on_terrain_maps_changed)
    scatter.terrain_id = terrain.get_instance_id() if terrain else 0
    scatter.maps_data_id = terrain.data.get_instance_id() if terrain and terrain.data else 0
    # counted, as the grasses' (grass_set_terrain())
    if scatter.maps_data_id:
        terrain.data.maps_changed.connect(_on_terrain_maps_changed, CONNECT_REFERENCE_COUNTED)
    _clear(scatter)


## The biome's settings (Biomes.get_config()) and its mask image (null: none); what was grown goes
## and grows again
func scatter_configure(rid: RID, config: Dictionary, mask: Image) -> void:
    var scatter: Scatter = _scatters.get(rid)
    # the worker threads read the settings: they are done before the settings change
    _clear(scatter)
    scatter.config = config
    scatter.mask = mask
    scatter.entries = _resolve_entries(config["entries"],
            config["billboard_shader"] if config["billboard_shader"] else BILLBOARD_SHADER)


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
    scatter.plan = []
    _far_free(scatter)


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
        if scatter.config.get("far_canopy", false):
            var begin: float = _generation_distance(scatter.config)
            if not begin == _canopy_begin:
                _canopy_begin = begin
                RenderingServer.global_shader_parameter_set(CANOPY_BEGIN_PARAMETER, begin)


## How far the biome's chunks grow from the camera [m]
static func _generation_distance(config: Dictionary) -> float:
    if config["follow_draw_distance"] and Engine.has_singleton(&"SceneryStreamingServer"):
        return minf(Engine.get_singleton(&"SceneryStreamingServer").streaming_get_draw_distance(),
                config["max_generation_distance_cap"])
    return config["max_generation_distance"]


## The biome's chunks within its distance of the camera grown, nearest first: CHUNK_TASKS at once
## worked out on the worker threads, each made as soon as it is done (_chunk_done()), which hands out
## the next; as the camera enters another chunk the ones out of the distance dropped
func _stream_scatter(scatter: Scatter, camera_position: Vector3) -> void:
    var config: Dictionary = scatter.config
    var size: float = config["chunk_size"]
    var camera_local: Vector3 = scatter.transform.affine_inverse() * camera_position
    var camera_chunk: Vector2i = Vector2i(floori(camera_local.x / size), floori(camera_local.z / size))
    var distance: float = _generation_distance(config)
    var terrain: Node3D = instance_from_id(scatter.terrain_id) as Node3D if scatter.terrain_id else null
    # the far trees on the GPU when they can be, made again as their distance changes
    var far_possible: bool = _far_possible(scatter, terrain)
    if not far_possible == not scatter.far.is_empty() or (scatter.far and not scatter.far["distance"] == distance):
        _clear(scatter)
        if far_possible:
            _far_create(scatter, distance)
    # with them the CPU grows the chunks whose models can be drawn: within the farthest billboard
    # distance of the camera, give or take half a chunk's diagonal
    if scatter.far:
        distance = minf(distance, _models_reach(scatter) + size * sqrt(2.0) * 0.5)
    if not scatter.plan == [distance, size]:
        _plan_chunks(scatter, distance, size)
    if not scatter.center == camera_chunk:
        scatter.center = camera_chunk
        scatter.next = 0
        for coords: Vector2i in scatter.chunks.keys():
            if not _chunk_needed(scatter, coords, distance, size):
                _drop_chunk(scatter, coords)
    _hand_out_chunks(scatter)
    if config["density_lod_enabled"]:
        _apply_density(scatter, camera_local)
    if scatter.far:
        scatter.view = camera_position
        for chunk: Dictionary in scatter.chunks.values():
            _apply_visibility(scatter, chunk)
        _far_follow(scatter, terrain, camera_local)


## The next chunks to grow handed to the worker threads, nearest first, up to CHUNK_TASKS at once
func _hand_out_chunks(scatter: Scatter) -> void:
    var distance: float = scatter.plan[0]
    var size: float = scatter.plan[1]
    var terrain: Node3D = instance_from_id(scatter.terrain_id) as Node3D if scatter.terrain_id else null
    while scatter.tasks.size() < CHUNK_TASKS and scatter.next < scatter.offsets.size():
        var coords: Vector2i = scatter.center + scatter.offsets[scatter.next]
        scatter.next += 1
        if scatter.chunks.has(coords) or scatter.tasks.has(coords) or not _chunk_needed(scatter, coords, distance, size):
            continue
        var generation: int = scatter.generation
        scatter.tasks[coords] = WorkerThreadPool.add_task(
                _grow_chunk.bind(scatter, coords, generation, _terrain_job(scatter, terrain, coords)) if terrain \
                else _generate_points.bind(scatter, coords, generation))


## On the main thread, called by a worker thread as its chunk is done: the chunk queued to be made
## (_make_done_chunks()), the frames followed while any is
func _chunk_done(scatter: Scatter, coords: Vector2i, generation: int) -> void:
    if _done.is_empty():
        get_tree().process_frame.connect(_make_done_chunks)
    _done.append([scatter, coords, generation])


## A frame's work while the worker threads' chunks wait: as many made as CHUNK_MAKE_BUDGET_USEC lets
## (_make_done_chunk()), the frames let go of once none is left
func _make_done_chunks() -> void:
    var deadline: int = Time.get_ticks_usec() + CHUNK_MAKE_BUDGET_USEC
    while _done and Time.get_ticks_usec() < deadline:
        var done: Array = _done.pop_front()
        _make_done_chunk(done[0], done[1], done[2])
    if _done.is_empty():
        get_tree().process_frame.disconnect(_make_done_chunks)


## The chunk a worker thread has done made, or let go of when no longer needed, out of date or grown
## on maps of before; the next one handed out. Nothing when the biome let its tasks go meanwhile
## (_clear(), scatter_free()).
func _make_done_chunk(scatter: Scatter, coords: Vector2i, generation: int) -> void:
    if not scatter.tasks.has(coords) or not generation == scatter.generation:
        return
    WorkerThreadPool.wait_for_task_completion(scatter.tasks[coords])
    scatter.tasks.erase(coords)
    scatter.mutex.lock()
    var worked: Variant = scatter.points.get(coords, [])
    scatter.points.erase(coords)
    scatter.mutex.unlock()
    if _chunk_needed(scatter, coords, scatter.plan[0], scatter.plan[1]):
        if worked is Dictionary:
            # grown where a region was missing on the maps of before: it grows again on the new ones
            if worked["missing"] and not worked["terrain_stamp"] == scatter.terrain_stamp:
                scatter.next = 0
            else:
                _make_chunk(scatter, coords, worked)
        else:
            _build_chunk(scatter, coords, worked)
    _hand_out_chunks(scatter)


## The chunks' offsets from the camera's chunk within [param distance] of it (their middles' from the
## camera's chunk's), nearest first (offsets)
func _plan_chunks(scatter: Scatter, distance: float, size: float) -> void:
    var radius: int = ceili(distance / size)
    var found: Array[Vector2i] = []
    # nearest first: an offset's squared length above its index in found, sorted natively
    var keys: PackedInt64Array = PackedInt64Array()
    for x in range(-radius, radius + 1):
        for z in range(-radius, radius + 1):
            if Vector2(x, z).length() * size <= distance:
                keys.append((Vector2i(x, z).length_squared() << 32) | found.size())
                found.append(Vector2i(x, z))
    keys.sort()
    scatter.offsets.clear()
    for key: int in keys:
        scatter.offsets.append(found[key & HASH_MASK])
    scatter.plan = [distance, size]
    scatter.center = Vector2i.MAX


## Whether the chunk [param coords] is to be grown: within [param distance] of the camera's chunk
## (scatter.center) and within the biome's area_size
static func _chunk_needed(scatter: Scatter, coords: Vector2i, distance: float, size: float) -> bool:
    var half_area: Vector2 = scatter.config["area_size"] * 0.5
    var middle: Vector2 = (Vector2(coords) + Vector2(0.5, 0.5)) * size
    if absf(middle.x) - size * 0.5 > half_area.x or absf(middle.y) - size * 0.5 > half_area.y:
        return false
    return Vector2(coords - scatter.center).length() * size <= distance


## On a worker thread: the candidate points of a chunk (_chunk_points()), stood on the surface by
## the main thread (_build_chunk()) - without a terrain
func _generate_points(scatter: Scatter, coords: Vector2i, generation: int) -> void:
    var points: Array = _chunk_points(scatter, coords)
    scatter.mutex.lock()
    if generation == scatter.generation:
        scatter.points[coords] = points
    scatter.mutex.unlock()
    _chunk_done.call_deferred(scatter, coords, generation)


## The candidate points of a chunk - one per cell of the spacing, jittered by a hash of the cell,
## kept by the mask's density, given an entry, a scale and a turn
static func _chunk_points(scatter: Scatter, coords: Vector2i) -> Array:
    var config: Dictionary = scatter.config
    var seed_value: int = config["seed"]
    var size: float = config["chunk_size"]
    var area_size: Vector2 = config["area_size"]
    var chunk_min: Vector2 = Vector2(coords) * size
    var chunk_max: Vector2 = chunk_min + Vector2(size, size)
    var half_area: Vector2 = area_size * 0.5
    var spacing: float = _spacing(config)
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
    return points


## The cells' spacing of a biome's points: its average_spacing, larger where max_instances caps them
static func _spacing(config: Dictionary) -> float:
    var area_size: Vector2 = config["area_size"]
    var spacing: float = maxf(config["average_spacing"], 0.1)
    if config["max_instances"] > 0:
        spacing = maxf(spacing, sqrt(maxf(area_size.x * area_size.y, 0.0001) / float(config["max_instances"])))
    return spacing


## Whether a biome's billboards can be drawn on the GPU: on a terrain, the biome not turned, at most
## FAR_ENTRIES_MAX entries, each with a billboard of billboard.gdshader
static func _far_possible(scatter: Scatter, terrain: Node3D) -> bool:
    if not terrain or not terrain.data or not scatter.transform.basis.is_equal_approx(Basis.IDENTITY) \
            or scatter.entries.is_empty() or scatter.entries.size() > FAR_ENTRIES_MAX:
        return false
    for entry: Dictionary in scatter.entries:
        if not entry["billboard"]:
            return false
    return true


## How far a biome's models can be drawn: its farthest billboard_lod_distance
static func _models_reach(scatter: Scatter) -> float:
    var reach: float = 0.0
    for entry: Dictionary in scatter.entries:
        reach = maxf(reach, entry["billboard_lod_distance"])
    return reach


## The biome's billboards on the GPU within [param distance]: a particle a cell of the biome's spacing
## around the camera's anchor cell (billboards.gdshader places them as _chunk_points() and
## _grow_chunk() do), drawn as the entries' billboards (billboard_particles.gdshader)
func _far_create(scatter: Scatter, distance: float) -> void:
    var config: Dictionary = scatter.config
    var spacing: float = _spacing(config)
    var reach: float = distance + FAR_ANCHOR_STEP
    var rows: int = 2 * ceili(reach / spacing) + 1
    var process: ShaderMaterial = ShaderMaterial.new()
    process.shader = BILLBOARDS_SHADER
    var draw: ShaderMaterial = ShaderMaterial.new()
    draw.shader = config["far_billboard_shader"] if config["far_billboard_shader"] else BILLBOARD_PARTICLES_SHADER
    var quad: QuadMesh = QuadMesh.new()
    quad.material = draw
    var cumulative: PackedFloat32Array = PackedFloat32Array()
    var scale_low: PackedVector3Array = PackedVector3Array()
    var scale_high: PackedVector3Array = PackedVector3Array()
    var quad_size: PackedVector2Array = PackedVector2Array()
    var quad_lift: PackedFloat32Array = PackedFloat32Array()
    var colors: PackedColorArray = PackedColorArray()
    var brightness: PackedFloat32Array = PackedFloat32Array()
    var lods: PackedFloat32Array = PackedFloat32Array()
    var total: float = 0.0
    # the shaders' arrays all FAR_ENTRIES_MAX long, the last entry repeated past the entries
    for index: int in FAR_ENTRIES_MAX:
        var entry: Dictionary = scatter.entries[mini(index, scatter.entries.size() - 1)]
        var billboard: ShaderMaterial = entry["billboard"]
        var part: Dictionary = entry["billboard_parts"][0]
        var size: Vector3 = (part["mesh"] as Mesh).get_aabb().size
        if index < scatter.entries.size():
            total += float(entry["probability"])
            draw.set_shader_parameter("albedo_%d" % index, billboard.get_shader_parameter("albedo_texture"))
        cumulative.append(total)
        scale_low.append(entry["scale_min"])
        scale_high.append(entry["scale_max"])
        quad_size.append(Vector2(size.x, size.y))
        quad_lift.append((part["transform"] as Transform3D).origin.y)
        # the array takes no source_color hint
        var color: Variant = billboard.get_shader_parameter("albedo_color")
        colors.append((color as Color).srgb_to_linear() if color is Color else Color.WHITE)
        var light: Variant = billboard.get_shader_parameter("brightness")
        brightness.append(float(light) if light != null else 1.0)
        lods.append(entry["billboard_lod_distance"])
    var origin: Vector2 = Vector2(scatter.transform.origin.x, scatter.transform.origin.z)
    var masked: bool = config["mask_enabled"] and scatter.mask != null
    for parameter: Array in [["seed", config["seed"]], ["spacing", spacing], ["half_area", config["area_size"] * 0.5],
            ["origin", origin], ["entry_count", scatter.entries.size()], ["cumulative", cumulative], ["scale_low", scale_low],
            ["scale_high", scale_high], ["quad_size", quad_size], ["quad_lift", quad_lift], ["rows", rows], ["reach", reach],
            ["terrain_texture", config["terrain_texture"]], ["autoshader_mode", config["terrain_autoshader"]],
            ["use_overlay", config["terrain_overlay"]], ["mask_enabled", masked], ["mask_channel", config["mask_channel"]],
            ["mask_threshold", config["mask_threshold"]], ["mask_inverse", config["mask_inverse"]],
            ["mask_affects_density", config["mask_affects_density"]]]:
        process.set_shader_parameter(parameter[0], parameter[1])
    if masked:
        process.set_shader_parameter("mask_texture", ImageTexture.create_from_image(scatter.mask))
    for parameter: Array in [["albedo_color", colors], ["brightness", brightness], ["lod_distance", lods],
            ["chunk_origin", origin], ["chunk_size", config["chunk_size"]], ["max_distance", distance]]:
        draw.set_shader_parameter(parameter[0], parameter[1])
    var particles: RID = RenderingServer.particles_create()
    RenderingServer.particles_set_mode(particles, RenderingServer.PARTICLES_MODE_3D)
    RenderingServer.particles_set_amount(particles, rows * rows)
    RenderingServer.particles_set_lifetime(particles, PARTICLES_LIFETIME)
    RenderingServer.particles_set_explosiveness_ratio(particles, 1.0)
    RenderingServer.particles_set_use_local_coordinates(particles, false)
    RenderingServer.particles_set_process_material(particles, process.get_rid())
    RenderingServer.particles_set_draw_passes(particles, 1)
    RenderingServer.particles_set_draw_pass_mesh(particles, 0, quad.get_rid())
    RenderingServer.particles_set_emitting(particles, true)
    var instance: RID = RenderingServer.instance_create2(particles, scatter.scenario)
    RenderingServer.instance_geometry_set_cast_shadows_setting(instance, _shadows(scatter))
    scatter.far = {"particles": particles, "instance": instance, "process": process, "draw": draw, "quad": quad,
            "spacing": spacing, "reach": reach, "distance": distance, "anchor": Vector2i.MAX}


## The far trees after the camera: the draw pass told where it is (as the CPU decided what is drawn
## where this tick), the grid restarted on the terrain's maps as its anchor cell - the camera's cell
## snapped to FAR_ANCHOR_STEP - moves, or the maps changed (anchor reset)
func _far_follow(scatter: Scatter, terrain: Node3D, camera_local: Vector3) -> void:
    var far: Dictionary = scatter.far
    RenderingServer.material_set_param(far["draw"].get_rid(), "view_position", scatter.view)
    var spacing: float = far["spacing"]
    var step: int = maxi(1, roundi(FAR_ANCHOR_STEP / spacing))
    var anchor: Vector2i = Vector2i(floori(camera_local.x / spacing / step) * step, floori(camera_local.z / spacing / step) * step)
    if anchor == far["anchor"]:
        return
    far["anchor"] = anchor
    var process: RID = far["process"].get_rid()
    _set_terrain_maps(process, terrain)
    RenderingServer.material_set_param(process, "anchor", anchor)
    var reach: float = far["reach"]
    var middle: Vector3 = scatter.transform * Vector3((anchor.x + 0.5) * spacing, 0.0, (anchor.y + 0.5) * spacing)
    var heights: Vector2 = terrain.data.get_height_range()
    RenderingServer.particles_set_custom_aabb(far["particles"], AABB(Vector3(middle.x - reach, heights.x, middle.z - reach),
            Vector3(reach * 2.0, heights.y - heights.x + FAR_TREE_HEIGHT_MAX, reach * 2.0)))
    RenderingServer.particles_restart(far["particles"])


## The far trees let go of
func _far_free(scatter: Scatter) -> void:
    if scatter.far.is_empty():
        return
    RenderingServer.free_rid(scatter.far["instance"])
    RenderingServer.free_rid(scatter.far["particles"])
    scatter.far = {}
    scatter.view = Vector3.INF


## On the main thread: what a chunk grown on [param terrain] is worked out of on a worker thread
## (_grow_chunk()), all of it the task's own - the maps of the terrain's regions under the chunk (a
## region taken out of the terrain meanwhile keeps its maps for the task) and how the biome reads them
func _terrain_job(scatter: Scatter, terrain: Node3D, coords: Vector2i) -> Dictionary:
    var config: Dictionary = scatter.config
    var spacing: float = terrain.vertex_spacing
    var region_size: int = terrain.region_size
    var size: float = config["chunk_size"]
    var corner: Vector2 = Vector2(coords) * size
    var a: Vector3 = scatter.transform * Vector3(corner.x, 0.0, corner.y)
    var b: Vector3 = scatter.transform * Vector3(corner.x + size, 0.0, corner.y + size)
    # the vertices read: a vertex more around for the heights between vertices and the slopes
    var first: Vector2i = Vector2i(floori(minf(a.x, b.x) / spacing) - 1, floori(minf(a.z, b.z) / spacing) - 1)
    var last: Vector2i = Vector2i(ceili(maxf(a.x, b.x) / spacing) + 2, ceili(maxf(a.z, b.z) / spacing) + 2)
    var regions: Dictionary = {}
    for x in range(floori(float(first.x) / region_size), floori(float(last.x) / region_size) + 1):
        for z in range(floori(float(first.y) / region_size), floori(float(last.y) / region_size) + 1):
            var region: Object = terrain.data.get_region(Vector2i(x, z))
            if region and not region.is_deleted():
                regions[Vector2i(x, z)] = [region.get_height_map(), region.get_control_map()]
    var job: Dictionary = {"spacing": spacing, "region_size": region_size, "regions": regions,
            "vertices": Rect2i(first, last - first + Vector2i.ONE), "terrain_stamp": scatter.terrain_stamp,
            "auto_shader": terrain.material.get_auto_shader(), "far": not scatter.far.is_empty()}
    for parameter: Array in [["auto_slope", AUTO_SLOPE_DEFAULT], ["auto_height_reduction", AUTO_HEIGHT_REDUCTION_DEFAULT],
            ["auto_base_texture", AUTO_BASE_TEXTURE_DEFAULT], ["auto_overlay_texture", AUTO_OVERLAY_TEXTURE_DEFAULT]]:
        job[parameter[0]] = _material_param(terrain, parameter[0], parameter[1])
    return job


## On a worker thread: a chunk grown on the job's maps (_terrain_job()) - its points
## (_chunk_points()) stood on the terrain where it grows on the biome's texture, and per entry and
## model part the buffer of a near MultiMesh, and of a billboard one past the entry's
## billboard_lod_distance; the main thread only makes them (_make_chunk())
func _grow_chunk(scatter: Scatter, coords: Vector2i, generation: int, job: Dictionary) -> void:
    var config: Dictionary = scatter.config
    var maps: Dictionary = _terrain_maps(job)
    var inverse: Transform3D = scatter.transform.affine_inverse()
    var center: Vector3 = _chunk_center(coords, config["chunk_size"])
    var texture_needed: bool = not config["terrain_texture"] == TERRAIN_TEXTURE_ANYWHERE
    # entry index -> [entry, transforms (local), priorities]
    var buckets: Dictionary = {}
    # a point where the terrain has no region yet: the chunk grows again when its maps change
    var missing: bool = false
    for point: Dictionary in _chunk_points(scatter, coords):
        var global: Vector3 = scatter.transform * (point["position"] as Vector3)
        var height: float = _map_height(job, maps, global.x, global.z)
        if is_nan(height):
            missing = true
            continue
        if texture_needed and not _map_texture(job, maps, config, global.x, global.z) == config["terrain_texture"]:
            continue
        var entry: Dictionary = point["entry"]
        if not buckets.has(entry["index"]):
            buckets[entry["index"]] = [entry, [], []]
        buckets[entry["index"]][1].append(Transform3D(Basis.IDENTITY.rotated(Vector3.UP, point["yaw"]).scaled(point["scale"]),
                inverse * Vector3(global.x, height, global.z)))
        buckets[entry["index"]][2].append(point["priority"])
    # per part: [mesh, buffer, instances, range begin, range end, PartShadow]
    var parts: Array = []
    var count: int = 0
    for bucket: Array in buckets.values():
        var entry: Dictionary = bucket[0]
        # the instances in the order the density LOD drops them: the highest priority last
        var order: Array = range(bucket[1].size())
        order.sort_custom(func(a: int, b: int) -> bool: return bucket[2][a] < bucket[2][b])
        var transforms: Array[Transform3D] = []
        for index: int in order:
            transforms.append(bucket[1][index])
        var near_end: float = _near_end(entry)
        var lod: float = entry["billboard_lod_distance"]
        var mid: float = _mid_start(entry, near_end)
        var shadows: Array = entry["shadow_parts"]
        var model_shadow: PartShadow = PartShadow.NONE if shadows else PartShadow.CAST
        for group: Array in [[entry["main_parts"], 0.0, mid, model_shadow], [entry["mid_parts"], mid, near_end, model_shadow],
                [shadows, 0.0, near_end, PartShadow.ONLY],
                # the billboards on the GPU with the far trees
                [[] if job["far"] else entry["billboard_parts"], lod if lod > 0.0 else 0.0, 0.0, PartShadow.CAST]]:
            for part: Dictionary in group[0]:
                if part["mesh"]:
                    parts.append([part["mesh"], _part_buffer(transforms, part["transform"], center), transforms.size(),
                            group[1], group[2], group[3]])
        count += transforms.size()
    scatter.mutex.lock()
    if generation == scatter.generation:
        scatter.points[coords] = {"parts": parts, "count": count, "center": center, "missing": missing,
                "terrain_stamp": job["terrain_stamp"]}
    scatter.mutex.unlock()
    _chunk_done.call_deferred(scatter, coords, generation)


## On the main thread: the chunk grown (_grow_chunk()) drawn - a MultiMesh and its instance a part
func _make_chunk(scatter: Scatter, coords: Vector2i, grown: Dictionary) -> void:
    var center: Vector3 = grown["center"]
    var chunk: Dictionary = {"multimeshes": [], "instances": [], "lods": [], "shadows": [], "ranges": [],
            "count": grown["count"], "visible": -1, "center": center, "missing": grown["missing"]}
    var chunk_transform: Transform3D = scatter.transform * Transform3D(Basis.IDENTITY, center)
    for part: Array in grown["parts"]:
        _add_multimesh(scatter, chunk, chunk_transform, part[0], part[1], part[2], part[3], part[4], part[5])
    _apply_visibility(scatter, chunk)
    scatter.chunks[coords] = chunk


## The job's maps cut to the vertices it reads: region location -> [first vertex (global), width,
## heights (PackedFloat32Array), controls (PackedInt32Array, the bits as they are), height]
static func _terrain_maps(job: Dictionary) -> Dictionary:
    var maps: Dictionary = {}
    var region_size: int = job["region_size"]
    var wanted: Rect2i = job["vertices"]
    for location: Vector2i in job["regions"]:
        var origin: Vector2i = location * region_size
        var part: Rect2i = wanted.intersection(Rect2i(origin, Vector2i(region_size, region_size)))
        if not part.has_area():
            continue
        var local: Rect2i = Rect2i(part.position - origin, part.size)
        var height_map: Image = job["regions"][location][0]
        var control_map: Image = job["regions"][location][1]
        # the control map's bits as they are: a pixel read as a float may be a NaN, which loses bits
        maps[location] = [part.position, part.size.x, height_map.get_region(local).get_data().to_float32_array(),
                control_map.get_region(local).get_data().to_int32_array(), part.size.y]
    return maps


## The map of the vertex [param x], [param z] (global, in vertices) and the vertex's index in it; []
## where the job has none
static func _map_vertex(job: Dictionary, maps: Dictionary, x: int, z: int) -> Array:
    var region_size: int = job["region_size"]
    var map: Array = maps.get(Vector2i(floori(float(x) / region_size), floori(float(z) / region_size)), [])
    if map.is_empty():
        return []
    var at: Vector2i = Vector2i(x, z) - map[0]
    if at.x < 0 or at.y < 0 or at.x >= map[1] or at.y >= map[4]:
        return []
    return [map, at.y * map[1] + at.x]


## The control bits at the world's [param x], [param z] as Terrain3DData.get_control() reads them
## (the vertex at or before the point); -1 where there is no region
static func _map_control(job: Dictionary, maps: Dictionary, x: float, z: float) -> int:
    var spacing: float = job["spacing"]
    var vertex: Array = _map_vertex(job, maps, floori(x / spacing), floori(z / spacing))
    return vertex[0][3][vertex[1]] & HASH_MASK if vertex else -1


## The terrain's height at the world's [param x], [param z] as Terrain3DData.get_height() works it
## out - between its four vertices; NaN where there is no region or a hole
static func _map_height(job: Dictionary, maps: Dictionary, x: float, z: float) -> float:
    var control: int = _map_control(job, maps, x, z)
    if control < 0 or control & CONTROL_HOLE:
        return NAN
    var spacing: float = job["spacing"]
    var cell: Vector2 = Vector2(x, z) / spacing
    var first: Vector2i = Vector2i(floori(cell.x), floori(cell.y))
    var corners: PackedFloat32Array = PackedFloat32Array()
    for offset: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
        var vertex: Array = _map_vertex(job, maps, first.x + offset.x, first.y + offset.y)
        if not vertex:
            return NAN
        corners.append(vertex[0][2][vertex[1]])
    var weight: Vector2 = cell - Vector2(first)
    return lerpf(lerpf(corners[0], corners[1], weight.x), lerpf(corners[2], corners[3], weight.x), weight.y)


## The terrain's texture at the world's [param x], [param z] as the biome reads it - as
## _terrain_texture_at() does on the terrain itself (the normal as Terrain3DData.get_normal())
static func _map_texture(job: Dictionary, maps: Dictionary, config: Dictionary, x: float, z: float) -> int:
    var control: int = _map_control(job, maps, x, z)
    var base: int = control >> CONTROL_BASE_SHIFT & CONTROL_ID_MASK
    var overlay: int = control >> CONTROL_OVERLAY_SHIFT & CONTROL_ID_MASK
    var blend: float = float(control >> CONTROL_BLEND_SHIFT & CONTROL_BLEND_MASK) / CONTROL_BLEND_MASK
    if control & CONTROL_AUTO:
        if config["terrain_autoshader"] == TerrainAutoshader.NOTHING:
            return TERRAIN_TEXTURE_ANYWHERE
        if config["terrain_autoshader"] == TerrainAutoshader.AUTOSHADER_TEXTURE and job["auto_shader"]:
            base = job["auto_base_texture"]
            overlay = job["auto_overlay_texture"]
            var spacing: float = job["spacing"]
            var height: float = _map_height(job, maps, x, z)
            var normal: Vector3 = Vector3(height - _map_height(job, maps, x + spacing, z), spacing,
                    height - _map_height(job, maps, x, z + spacing)).normalized()
            # Terrain3D's shader: lightweight.gdshader:258
            blend = clampf(job["auto_slope"] * 2.0 * (normal.y - 1.0) + 1.0
                    - job["auto_height_reduction"] * 0.01 * height, 0.0, 1.0)
    return overlay if config["terrain_overlay"] and blend >= OVERLAY_BLEND_SHOWN else base


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
    # a point where the terrain has no region yet: the chunk grows again when its maps change
    var missing: bool = false
    for point: Dictionary in points:
        var local: Vector3 = point["position"]
        var global: Vector3 = scatter.transform * local
        var surface: Variant = _surface_at(scatter, terrain, state, local, global)
        if surface == null:
            missing = missing or terrain != null
            continue
        if terrain and not config["terrain_texture"] == TERRAIN_TEXTURE_ANYWHERE \
                and not _terrain_texture_at(terrain, config, global) == config["terrain_texture"]:
            continue
        var entry: Dictionary = point["entry"]
        if not buckets.has(entry["index"]):
            buckets[entry["index"]] = [entry, [], []]
        buckets[entry["index"]][1].append(Transform3D(
                Basis.IDENTITY.rotated(Vector3.UP, point["yaw"]).scaled(point["scale"]), surface))
        buckets[entry["index"]][2].append(point["priority"])
    var chunk: Dictionary = {"multimeshes": [], "instances": [], "lods": [], "shadows": [], "ranges": [], "count": 0,
            "visible": -1, "center": center, "missing": missing}
    var chunk_transform: Transform3D = scatter.transform * Transform3D(Basis.IDENTITY, center)
    for bucket: Array in buckets.values():
        var entry: Dictionary = bucket[0]
        # the instances in the order the density LOD drops them: the highest priority last
        var order: Array = range(bucket[1].size())
        order.sort_custom(func(a: int, b: int) -> bool: return bucket[2][a] < bucket[2][b])
        var transforms: Array[Transform3D] = []
        for index: int in order:
            transforms.append(bucket[1][index])
        var near_end: float = _near_end(entry)
        var lod: float = entry["billboard_lod_distance"]
        var mid: float = _mid_start(entry, near_end)
        var shadows: Array = entry["shadow_parts"]
        var model_shadow: PartShadow = PartShadow.NONE if shadows else PartShadow.CAST
        _add_multimeshes(scatter, chunk, chunk_transform, entry["main_parts"], transforms, center, 0.0, mid, model_shadow)
        _add_multimeshes(scatter, chunk, chunk_transform, entry["mid_parts"], transforms, center, mid, near_end, model_shadow)
        _add_multimeshes(scatter, chunk, chunk_transform, shadows, transforms, center, 0.0, near_end, PartShadow.ONLY)
        _add_multimeshes(scatter, chunk, chunk_transform, entry["billboard_parts"], transforms, center,
                lod if lod > 0.0 else 0.0, 0.0, PartShadow.CAST)
        chunk["count"] += transforms.size()
    _apply_visibility(scatter, chunk)
    scatter.chunks[coords] = chunk


## A MultiMesh and its instance per part, the transforms relative to the chunk's centre, drawn from
## [param range_begin] to [param range_end] (0: no limit), their shadow [param shadow]
func _add_multimeshes(scatter: Scatter, chunk: Dictionary, chunk_transform: Transform3D, parts: Array,
        transforms: Array[Transform3D], center: Vector3, range_begin: float, range_end: float, shadow: PartShadow) -> void:
    for part: Dictionary in parts:
        if part["mesh"]:
            _add_multimesh(scatter, chunk, chunk_transform, part["mesh"], _part_buffer(transforms, part["transform"], center),
                    transforms.size(), range_begin, range_end, shadow)


## Where an entry's model (or its mid model) ends: its billboards' distance, 0 (no limit) without
## billboards
static func _near_end(entry: Dictionary) -> float:
    var lod: float = entry["billboard_lod_distance"]
    return lod if entry["billboard_parts"] and lod > 0.0 else 0.0


## Where an entry's mid model takes over from its model: mid_lod_distance, within [param near_end];
## near_end itself (the model all the way) without a mid model
static func _mid_start(entry: Dictionary, near_end: float) -> float:
    if not entry["mid_parts"]:
        return near_end
    var mid: float = entry["mid_lod_distance"]
    return minf(mid, near_end) if near_end > 0.0 else mid


## The MultiMesh buffer of the part [param part_transform] of the models at [param transforms],
## relative to the chunk's centre
static func _part_buffer(transforms: Array[Transform3D], part_transform: Transform3D, center: Vector3) -> PackedFloat32Array:
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
    return buffer


## A MultiMesh of [param mesh] with [param buffer] ([param count] instances) and its instance in the
## chunk, drawn from [param range_begin] to [param range_end] (0: no limit), its shadow [param shadow]
func _add_multimesh(scatter: Scatter, chunk: Dictionary, chunk_transform: Transform3D, mesh: Mesh,
        buffer: PackedFloat32Array, count: int, range_begin: float, range_end: float, shadow: PartShadow) -> void:
    var multimesh: RID = RenderingServer.multimesh_create()
    RenderingServer.multimesh_set_mesh(multimesh, mesh.get_rid())
    RenderingServer.multimesh_allocate_data(multimesh, count, RenderingServer.MULTIMESH_TRANSFORM_3D)
    RenderingServer.multimesh_set_buffer(multimesh, buffer)
    var instance: RID = RenderingServer.instance_create2(multimesh, scatter.scenario)
    RenderingServer.instance_set_transform(instance, chunk_transform)
    _apply_part_shadow(scatter, instance, shadow)
    # with the far trees the ranges are the chunk's (_apply_visibility()), as the GPU's are
    if not scatter.far and (range_begin > 0.0 or range_end > 0.0):
        RenderingServer.instance_geometry_set_visibility_range(instance, range_begin, range_end, 0.0, 0.0,
                RenderingServer.VISIBILITY_RANGE_FADE_DISABLED)
    chunk["multimeshes"].append(multimesh)
    chunk["instances"].append(instance)
    chunk["lods"].append(count)
    chunk["shadows"].append(shadow)
    chunk["ranges"].append(Vector2(range_begin, range_end))


## The biome's shadows as the quality lets it cast them
func _shadows(scatter: Scatter) -> RenderingServer.ShadowCastingSetting:
    return scatter.config["shadow_casting"] as RenderingServer.ShadowCastingSetting if scatter.high_quality \
            else RenderingServer.SHADOW_CASTING_SETTING_OFF


## An instance's shadow by its part's [param shadow]: the biome's, none, or the shadow alone
func _apply_part_shadow(scatter: Scatter, instance: RID, shadow: PartShadow) -> void:
    match shadow:
        PartShadow.CAST:
            RenderingServer.instance_geometry_set_cast_shadows_setting(instance, _shadows(scatter))
        PartShadow.NONE:
            RenderingServer.instance_geometry_set_cast_shadows_setting(instance, RenderingServer.SHADOW_CASTING_SETTING_OFF)
        PartShadow.ONLY:
            RenderingServer.instance_geometry_set_cast_shadows_setting(instance, RenderingServer.SHADOW_CASTING_SETTING_SHADOWS_ONLY)


## What of a chunk is drawn: a shadows-only part not when the biome casts no shadows (drawn as it is
## then); with the far trees a part within its range of the chunk's middle's horizontal distance from
## the camera (scatter.view) - as billboard_particles.gdshader hides the GPU's billboards there
func _apply_visibility(scatter: Scatter, chunk: Dictionary) -> void:
    var casting: bool = not _shadows(scatter) == RenderingServer.SHADOW_CASTING_SETTING_OFF
    var from_view: float = INF
    if scatter.far and scatter.view.is_finite():
        var middle: Vector3 = scatter.transform * (chunk["center"] as Vector3)
        from_view = Vector2(middle.x, middle.z).distance_to(Vector2(scatter.view.x, scatter.view.z))
    for index: int in chunk["instances"].size():
        var visible: bool = casting or not chunk["shadows"][index] == PartShadow.ONLY
        if scatter.far:
            var part_range: Vector2 = chunk["ranges"][index]
            visible = visible and from_view >= part_range.x and (part_range.y <= 0.0 or from_view < part_range.y)
        RenderingServer.instance_set_visible(chunk["instances"][index], visible)


func _apply_shadows(scatter: Scatter) -> void:
    for chunk: Dictionary in scatter.chunks.values():
        for index: int in chunk["instances"].size():
            _apply_part_shadow(scatter, chunk["instances"][index], chunk["shadows"][index])
        _apply_visibility(scatter, chunk)
    if scatter.far:
        RenderingServer.instance_geometry_set_cast_shadows_setting(scatter.far["instance"], _shadows(scatter))


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


## The entries made drawable: their models' mesh parts (with the materials of their instances), their
## mid models' and shadow meshes', and billboard parts (billboard.gdshader), the billboards' materials
## kept on the entry for its brightness
## The entries made drawable, their billboards drawn with [param billboard_shader]
func _resolve_entries(entries: Array, billboard_shader: Shader) -> Array[Dictionary]:
    var resolved: Array[Dictionary] = []
    var billboard_cache: Dictionary = {}
    for index: int in entries.size():
        var entry: BiomeScatterEntry = entries[index]
        if not entry:
            continue
        var main_parts: Array[Dictionary] = _mesh_parts(entry.mesh_scene, entry.mesh, null, billboard_cache)
        if main_parts.is_empty() or entry.probability <= 0.0:
            continue
        var billboard_parts: Array[Dictionary] = _mesh_parts(entry.billboard_scene, entry.billboard_mesh, billboard_shader, billboard_cache)
        var shadow_parts: Array[Dictionary] = _mesh_parts(entry.shadow_scene, null, null, billboard_cache)
        var mid_parts: Array[Dictionary] = _mesh_parts(entry.mid_scene, null, null, billboard_cache)
        entry.billboard_materials.clear()
        for part: Dictionary in billboard_parts:
            var part_mesh: Mesh = part["mesh"]
            for surface: int in part_mesh.get_surface_count():
                var material: ShaderMaterial = part_mesh.surface_get_material(surface) as ShaderMaterial
                if material and material.shader == billboard_shader:
                    material.set_shader_parameter("brightness", entry.billboard_brightness)
                    entry.billboard_materials.append(material)
        # its billboard's material (the GPU draws the far ones with its texture), null without one
        var billboard: ShaderMaterial = entry.billboard_materials[0] if entry.billboard_materials else null
        resolved.append({"index": index, "main_parts": main_parts, "billboard_parts": billboard_parts, "billboard": billboard,
                "shadow_parts": shadow_parts,
                "mid_parts": mid_parts, "mid_lod_distance": maxf(entry.mid_lod_distance, 0.0),
                "probability": entry.probability, "billboard_lod_distance": maxf(entry.billboard_lod_distance, 0.0),
                "scale_min": entry.scale_min, "scale_max": entry.scale_max})
    return resolved


## The meshes of [param scene] (else [param fallback]), drawn as billboards with [param billboard_shader]
## when one is given
func _mesh_parts(scene: PackedScene, fallback: Mesh, billboard_shader: Shader, cache: Dictionary) -> Array[Dictionary]:
    var parts: Array[Dictionary] = []
    var instance: Node = scene.instantiate() if scene else null
    if instance:
        _collect_mesh_parts(instance, Transform3D.IDENTITY, billboard_shader, parts, cache)
        instance.free()
    if parts.is_empty() and fallback:
        parts.append({"mesh": _billboard_mesh(fallback, billboard_shader, cache) if billboard_shader else fallback,
                "transform": Transform3D.IDENTITY})
    return parts


func _collect_mesh_parts(node: Node, parent: Transform3D, billboard_shader: Shader, parts: Array[Dictionary], cache: Dictionary) -> void:
    var local: Transform3D = parent * (node as Node3D).transform if node is Node3D else parent
    var mesh_instance: MeshInstance3D = node as MeshInstance3D
    if mesh_instance and mesh_instance.mesh:
        var mesh: Mesh = mesh_instance.mesh.duplicate(true) as Mesh
        for surface: int in mesh.get_surface_count():
            var material: Material = mesh_instance.get_active_material(surface)
            if material:
                mesh.surface_set_material(surface,
                        _billboard_material(material, billboard_shader) if billboard_shader and material is BaseMaterial3D else material)
        parts.append({"mesh": _billboard_mesh(mesh, billboard_shader, cache) if billboard_shader else mesh, "transform": local})
    for child: Node in node.get_children():
        _collect_mesh_parts(child, local, billboard_shader, parts, cache)


func _billboard_mesh(source: Mesh, billboard_shader: Shader, cache: Dictionary) -> Mesh:
    if cache.has(source.get_instance_id()):
        return cache[source.get_instance_id()]
    var mesh: Mesh = source.duplicate(true) as Mesh
    for surface: int in mesh.get_surface_count():
        var material: Material = mesh.surface_get_material(surface)
        if not material or material is BaseMaterial3D:
            mesh.surface_set_material(surface, _billboard_material(material, billboard_shader))
    cache[source.get_instance_id()] = mesh
    return mesh


## The far LOD's material: [param billboard_shader] (billboard.gdshader, or a game's own including
## billboard.gdshaderinc) with [param source]'s texture and colour (a BaseMaterial3D from the
## billboard generator; null gives a white one). BaseMaterial3D's own BILLBOARD_FIXED_Y lit the quad
## by a normal following the camera (see the shader).
static func _billboard_material(source: Material, billboard_shader: Shader) -> ShaderMaterial:
    var material: ShaderMaterial = ShaderMaterial.new()
    material.shader = billboard_shader
    var base: BaseMaterial3D = source as BaseMaterial3D
    if base:
        material.resource_name = base.resource_name
        material.set_shader_parameter("albedo_texture", base.albedo_texture)
        material.set_shader_parameter("albedo_color", base.albedo_color)
    return material
