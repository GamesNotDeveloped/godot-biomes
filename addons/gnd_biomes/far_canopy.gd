@tool
extends RefCounted
class_name BiomesFarCanopy
## The far canopy of a forest - a layer of trees (Biomes) with far_canopy - as a world's build bakes it
## with its far terrain: where the terrain has the layer's texture, a roof of the layer's Far Canopy
## Texture (its Far Texture without one) at the height of its trees, and walls of its trees' billboard where the forest ends - its edge
## seen on a slope from kilometres. Where a forest stands follows from the terrain alone, so the
## mesh is made once, with the world, and drawn whole (far_canopy.gdshader), from where the layer's
## trees end on (BiomesServer.CANOPY_BEGIN_PARAMETER).
## A build makes one a layer (layers()), gives it the ground and the control map around each area
## it bakes (add_area()) and adds the canopy to its mesh (add_to()).

const SHADER: Shader = preload("./far_canopy.gdshader")
## A cell's side [m]: a cell is forest by the control map at its middle - the far terrain's vertex
## every 32 m
const CELL: float = 32.0
## The roof at this share of the trees' height, under the tops of the billboards it fades in among;
## the walls reach the tops
const ROOF_SHARE: float = 0.8
## Terrain3D's far_albedo_uv_scale when its material does not set it (terrain3d_far.gdshader)
const FAR_ALBEDO_UV_SCALE_DEFAULT: float = 0.1
## Terrain3D's control map (terrain_3d_util.h): an autoshaded and a hole vertex's bits, the base and
## overlay texture's and the blend's
const CONTROL_AUTO: int = 0x1
const CONTROL_HOLE: int = 0x4
## Terrain3D shows the overlay texture where it is blended over this
const OVERLAY_BLEND_SHOWN: float = 0.5
## A wall's side of a cell: its corners' offsets from the cell's, and the neighbour's offset
const SIDES: Array = [[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, -1)], [Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 0)],
        [Vector2i(1, 1), Vector2i(0, 1), Vector2i(0, 1)], [Vector2i(0, 1), Vector2i(0, 0), Vector2i(-1, 0)]]

var _terrain_texture: int = -1
var _terrain_autoshader: int = 0
var _terrain_overlay: bool = true
## The trees' height [m], mean of the layer's by their probability
var _height: float = 0.0
## A tree's width along a wall [m]
var _wall_width: float = 1.0
var _material: ShaderMaterial
## The mesh baked since begin(): vertices (world), normals, colours (r: wall), uvs (the wall's), uv2s
## (world X, Z)
var _arrays: Array = []


## The canopies of the layers under [param root] (a biomes scene, instanced) that have one: far_canopy,
## a Far Texture, trees and a billboard of them
static func layers(root: Node) -> Array[BiomesFarCanopy]:
    var canopies: Array[BiomesFarCanopy] = []
    for node: Node in [root] + root.find_children("*", "", true, false):
        var canopy: BiomesFarCanopy = of_layer(node as Biomes) if node is Biomes else null
        if canopy:
            canopies.append(canopy)
    return canopies


## The canopy of [param biomes]; null when it has none
static func of_layer(biomes: Biomes) -> BiomesFarCanopy:
    if not biomes.far_canopy or not biomes.far_texture:
        return null
    var heights: float = 0.0
    var weights: float = 0.0
    var wall: BiomeScatterEntry = null
    for entry: BiomeScatterEntry in biomes.entries:
        if not entry or entry.probability <= 0.0:
            continue
        var model: Node = entry.mesh_scene.instantiate() if entry.mesh_scene else null
        var top: float = _top(model, Transform3D.IDENTITY) if model else \
                (entry.mesh.get_aabb().end.y if entry.mesh else -INF)
        if model:
            model.free()
        if is_inf(top):
            continue
        heights += top * (entry.scale_min.y + entry.scale_max.y) * 0.5 * entry.probability
        weights += entry.probability
        if entry.billboard_scene and (not wall or entry.probability > wall.probability):
            wall = entry
    if weights <= 0.0 or not wall:
        return null
    var billboard: Node = wall.billboard_scene.instantiate()
    var quads: Array[Node] = [billboard] if billboard is MeshInstance3D else billboard.find_children("*", "MeshInstance3D", true, false)
    var quad: MeshInstance3D = quads.front() as MeshInstance3D if quads else null
    var albedo: BaseMaterial3D = quad.get_active_material(0) as BaseMaterial3D if quad else null
    var quad_width: float = quad.mesh.get_aabb().size.x if quad else 0.0
    billboard.free()
    if not albedo or quad_width <= 0.0:
        return null
    var canopy: BiomesFarCanopy = BiomesFarCanopy.new()
    canopy._terrain_texture = biomes.terrain_texture
    canopy._terrain_autoshader = biomes.terrain_autoshader
    canopy._terrain_overlay = biomes.terrain_overlay
    canopy._height = heights / weights
    canopy._wall_width = quad_width * (wall.scale_min.x + wall.scale_max.x) * 0.5
    canopy._material = ShaderMaterial.new()
    canopy._material.shader = SHADER
    canopy._material.set_shader_parameter("far_tint", biomes.far_tint)
    canopy._material.set_shader_parameter("wall_texture", albedo.albedo_texture)
    canopy._material.set_shader_parameter("wall_brightness", wall.billboard_brightness)
    if biomes.far_canopy_texture:
        canopy._material.set_shader_parameter("roof_texture", biomes.far_canopy_texture)
        canopy._material.set_shader_parameter("roof_uv_scale", 1.0 / biomes.far_canopy_tile)
    else:
        # the Far Texture laid as the layer's terrain lays its far look
        var terrain_material: Object = biomes.terrain.get("material") if biomes.terrain else null
        var uv_scale: Variant = terrain_material.get_shader_param("far_albedo_uv_scale") if terrain_material else null
        canopy._material.set_shader_parameter("roof_texture", biomes.far_texture)
        canopy._material.set_shader_parameter("roof_uv_scale", float(uv_scale) if uv_scale != null else FAR_ALBEDO_UV_SCALE_DEFAULT)
    canopy.begin()
    return canopy


## A new mesh: what was baked goes
func begin() -> void:
    _arrays = [PackedVector3Array(), PackedVector3Array(), PackedColorArray(), PackedVector2Array(), PackedVector2Array()]


## Bakes the canopy over [param area] (world X, Z; its sides whole cells): [param ground] gives the
## ground's height at a point (x, z: float -> float, NaN where there is none), [param control] the
## control map's bits there (x, z: float -> int, -1 where there is none) - a cell around the area
## too, for the walls on its sides
func add_area(area: Rect2, ground: Callable, control: Callable) -> void:
    var cells: Vector2i = Vector2i(roundi(area.size.x / CELL), roundi(area.size.y / CELL))
    var corner: Vector2 = area.position
    # the ground at the cells' corners
    var side: int = cells.x + 1
    var heights: PackedFloat32Array = PackedFloat32Array()
    heights.resize(side * (cells.y + 1))
    for j in cells.y + 1:
        for i in side:
            heights[j * side + i] = ground.call(corner.x + i * CELL, corner.y + j * CELL)
    # the cells that are forest, with a ring of them around the area
    var ring: int = cells.x + 2
    var forest: PackedByteArray = PackedByteArray()
    forest.resize(ring * (cells.y + 2))
    for j in cells.y + 2:
        for i in ring:
            forest[j * ring + i] = 1 if _is_forest(control.call(corner.x + (i - 0.5) * CELL, corner.y + (j - 0.5) * CELL)) else 0
    var roof: float = _height * ROOF_SHARE
    for j in cells.y:
        for i in cells.x:
            if not forest[(j + 1) * ring + i + 1]:
                continue
            var quad: Array[Vector2i] = [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]
            var complete: bool = true
            for k: Vector2i in quad:
                complete = complete and not is_nan(heights[k.y * side + k.x])
            if not complete:
                continue
            for k: int in [0, 1, 2, 0, 2, 3]:
                var at: Vector2i = quad[k]
                var vertex: Vector3 = Vector3(corner.x + at.x * CELL, heights[at.y * side + at.x] + roof, corner.y + at.y * CELL)
                _arrays[0].append(vertex)
                _arrays[1].append(_slope(heights, side, cells, at))
                _arrays[2].append(Color.BLACK)
                _arrays[3].append(Vector2.ZERO)
                _arrays[4].append(Vector2(vertex.x, vertex.z))
            for wall: Array in SIDES:
                var beyond: Vector2i = Vector2i(i + 1, j + 1) + wall[2]
                if forest[beyond.y * ring + beyond.x]:
                    continue
                var a: Vector2i = Vector2i(i, j) + wall[0]
                var b: Vector2i = Vector2i(i, j) + wall[1]
                var ground_a: Vector3 = Vector3(corner.x + a.x * CELL, heights[a.y * side + a.x], corner.y + a.y * CELL)
                var ground_b: Vector3 = Vector3(corner.x + b.x * CELL, heights[b.y * side + b.x], corner.y + b.y * CELL)
                # the trees side by side along the wall, by the world's axis it runs along
                var u_a: float = (ground_a.x if a.y == b.y else ground_a.z) / _wall_width
                var u_b: float = (ground_b.x if a.y == b.y else ground_b.z) / _wall_width
                var corners: Array = [[ground_a, Vector2(u_a, 1.0)], [ground_b, Vector2(u_b, 1.0)],
                        [ground_b + Vector3.UP * _height, Vector2(u_b, 0.0)], [ground_a + Vector3.UP * _height, Vector2(u_a, 0.0)]]
                for k: int in [0, 1, 2, 0, 2, 3]:
                    _arrays[0].append(corners[k][0])
                    _arrays[1].append(Vector3.UP)
                    _arrays[2].append(Color.WHITE)
                    _arrays[3].append(corners[k][1])
                    _arrays[4].append(Vector2.ZERO)


## The canopy baked since begin() as a surface of [param mesh] (none when no forest was there);
## uncompressed - its uv2s are the world's coordinates
func add_to(mesh: ArrayMesh) -> void:
    if _arrays[0].is_empty():
        return
    var surface: Array = []
    surface.resize(Mesh.ARRAY_MAX)
    surface[Mesh.ARRAY_VERTEX] = _arrays[0]
    surface[Mesh.ARRAY_NORMAL] = _arrays[1]
    surface[Mesh.ARRAY_COLOR] = _arrays[2]
    surface[Mesh.ARRAY_TEX_UV] = _arrays[3]
    surface[Mesh.ARRAY_TEX_UV2] = _arrays[4]
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface)
    mesh.surface_set_material(mesh.get_surface_count() - 1, _material)


## Whether the control map's [param bits] are the layer's texture - as BiomesServer reads it
## (_terrain_texture_at()); the texture the autoshader would show by the slope is not known here, an
## autoshaded vertex counts by the texture painted there
func _is_forest(bits: int) -> bool:
    if bits < 0 or bits & CONTROL_HOLE:
        return false
    if bits & CONTROL_AUTO and _terrain_autoshader == Biomes.TerrainAutoshader.NOTHING:
        return false
    if _terrain_texture == Biomes.TERRAIN_TEXTURE_ANYWHERE:
        return true
    var base: int = bits >> 27 & 0x1F
    var overlay: int = bits >> 22 & 0x1F
    var blend: float = float(bits >> 14 & 0xFF) / 255.0
    return (overlay if _terrain_overlay and blend >= OVERLAY_BLEND_SHOWN else base) == _terrain_texture


## The roof's normal at the corner [param at]: the slope of the corners around (its own height
## where one has none)
static func _slope(heights: PackedFloat32Array, side: int, cells: Vector2i, at: Vector2i) -> Vector3:
    var own: float = heights[at.y * side + at.x]
    var east: float = heights[at.y * side + mini(at.x + 1, cells.x)]
    var west: float = heights[at.y * side + maxi(at.x - 1, 0)]
    var south: float = heights[mini(at.y + 1, cells.y) * side + at.x]
    var north: float = heights[maxi(at.y - 1, 0) * side + at.x]
    return Vector3((own if is_nan(west) else west) - (own if is_nan(east) else east), 2.0 * CELL,
            (own if is_nan(north) else north) - (own if is_nan(south) else south)).normalized()


## The highest point of the meshes under [param node] [m]; -INF without one
static func _top(node: Node, parent: Transform3D) -> float:
    var local: Transform3D = parent * (node as Node3D).transform if node is Node3D else parent
    var top: float = -INF
    var mesh_instance: MeshInstance3D = node as MeshInstance3D
    if mesh_instance and mesh_instance.mesh:
        top = (local * mesh_instance.mesh.get_aabb()).end.y
    for child: Node in node.get_children():
        top = maxf(top, _top(child, local))
    return top
