@tool
extends EditorPlugin

const BIOMES_SCRIPT := preload("./Biomes.gd")
const ENTRY_SCRIPT := preload("./BiomeScatterEntry.gd")
const BIOMES_PANEL_SCRIPT := preload("./BiomesPanel.gd")
const SERVER_NAME := "BiomesServer"
const SERVER_PATH := "res://addons/gnd_biomes/biomes_server.gd"
# no TerrainPatch3D (a forest demo script) and no icon of the demo project
const BIOMES_ICON: Texture2D = null
const PANEL_TITLE := "Biomes"
const BILLBOARD_PADDING := 1.15
const OVERWRITE_SKIP := 0
const OVERWRITE_OVERWRITE := 1
const RESOLUTION_PRESETS := [256, 512, 1024]
## The canopy's tile: the shade between the crowns
const CANOPY_GAP_COLOR := Color(0.03, 0.045, 0.025)
## The canopy's tile is the forest seen from this over the horizon [deg] - as it is seen from afar;
## from above the trees' crossed cards show their edges - from so many sides around, their mean. The
## roof's from higher: its crowns leant less, its clumps and gaps are not smeared over each other.
const CANOPY_ELEVATION := 30.0
const CANOPY_ROOF_ELEVATION := 60.0
const CANOPY_VIEWS := 8
## The far canopy's roof tile: pixels as many times the chosen resolution - its tile is far larger
const CANOPY_ROOF_RESOLUTION := 2
## The roof tile's forest: the share of its trees standing, around which clumps and gaps go, by whole
## waves across the tile (x, z) - a few, so it repeats with the tile but not by one wave
## A mean's channel at least this, as an image is toned by it
const CANOPY_MEAN_MIN := 0.001
const CANOPY_CLUMP_DENSITY := 0.75
const CANOPY_CLUMP_AMPLITUDE := 1.0
const CANOPY_CLUMP_WAVES: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, -1), Vector2i(-2, 3), Vector2i(4, 1)]
## The terrain material's far_albedo_uv_scale when it does not set it (terrain3d_far.gdshader)
const FAR_ALBEDO_UV_SCALE_DEFAULT := 0.1
## A model simplified (a shadow mesh, a mid model): its solid parts (trunk, branches) kept to a share
## of their triangles by Godot's meshoptimizer, its cards (leaves) to a share of them, each grown to
## cover as much - a shadow's coarser than a mid model's, seen from 25 m on; a model of fewer
## triangles gets none - it costs no more itself
const SHADOW_SOLID_SHARE := 0.15
const SHADOW_CARD_SHARE := 0.2
const MID_SOLID_SHARE := 0.3
const MID_CARD_SHARE := 0.35
const SIMPLIFIED_MIN_TRIANGLES := 1000
## A surface whose pieces (triangles joined by their vertices) have this many triangles on average at
## most is of cards
const CARD_TRIANGLES_MAX := 4
## Godot's meshoptimizer LODs of a shadow mesh's solid parts: normals merged and split at these [deg]
const SHADOW_NORMAL_MERGE_ANGLE := 60.0
const SHADOW_NORMAL_SPLIT_ANGLE := 25.0
## The alpha scissor of a card's shadow when its material says none
const SHADOW_ALPHA_SCISSOR_DEFAULT := 0.5

var _current_biomes: Biomes
var _current_paint_target: Node3D
var _panel: VBoxContainer
var _biomes_panel: Control
# what a Biomes growing on a texture of its Terrain3D shows instead of the mask
var _terrain_texture_label: Label
var _billboard_separator: HSeparator
var _billboard_section: Label
var _billboard_row: HBoxContainer
var _billboard_resolution_option: OptionButton
var _billboard_output_dir_edit: LineEdit
var _billboard_output_dir_button: Button
var _generate_billboards_button: Button
var _generate_canopy_button: Button
var _generate_shadows_button: Button
var _generate_mids_button: Button
## What a simplified model is for: an entry's shadow mesh (shadow_scene, a material casting the shadow
## alone) or its mid model (mid_scene, the model's own materials)
enum Simplified { SHADOW, MID }
var _status_label: Label
var _save_dialog: FileDialog
var _billboard_dir_dialog: FileDialog
var _overwrite_dialog: ConfirmationDialog
var _clear_channel_dialog: ConfirmationDialog
var _overwrite_mode_option: OptionButton
var _stroke_active := false
var _stroke_before_image: Image
var _stroke_working_image: Image
var _last_painted_pixel := Vector2i(-1, -1)
var _pending_mask_path := ""
var _hover_screen_position := Vector2.ZERO
var _hover_world_position: Variant = null
var _billboard_generation_running := false


## The server growing the biomes, an autoload of the project the plugin is enabled in
func _enable_plugin() -> void:
    add_autoload_singleton(SERVER_NAME, SERVER_PATH)


func _disable_plugin() -> void:
    remove_autoload_singleton(SERVER_NAME)


func _enter_tree() -> void:
    add_custom_type("Biomes", "Node3D", BIOMES_SCRIPT, BIOMES_ICON)
    add_custom_type("BiomeScatterEntry", "Resource", ENTRY_SCRIPT, BIOMES_ICON)
    _build_panel()
    _build_file_dialog()
    _build_overwrite_dialog()
    _build_clear_channel_dialog()
    set_input_event_forwarding_always_enabled()
    set_force_draw_over_forwarding_enabled()
    # the panel follows terrain_texture as it is changed in the inspector
    EditorInterface.get_inspector().property_edited.connect(_on_property_edited)


func _exit_tree() -> void:
    EditorInterface.get_inspector().property_edited.disconnect(_on_property_edited)
    remove_custom_type("BiomeScatterEntry")
    remove_custom_type("Biomes")
    if _panel != null:
        remove_control_from_bottom_panel(_panel)
        _panel.queue_free()
    if _save_dialog != null:
        _save_dialog.queue_free()
    if _billboard_dir_dialog != null:
        _billboard_dir_dialog.queue_free()
    if _overwrite_dialog != null:
        _overwrite_dialog.queue_free()
    if _clear_channel_dialog != null:
        _clear_channel_dialog.queue_free()


func _handles(object: Object) -> bool:
    return object is Biomes


func _edit(object: Object) -> void:
    _current_biomes = object as Biomes
    _current_paint_target = object as Node3D
    _refresh_panel_state()


func _make_visible(visible: bool) -> void:
    if _panel != null:
        _panel.visible = visible and _current_paint_target != null


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
    if event is InputEventMouse:
        _hover_screen_position = event.position
        _hover_world_position = _intersect_mask_plane(camera, event.position) if _can_paint() else null
        update_overlays()

    if not _can_paint():
        return AFTER_GUI_INPUT_PASS

    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
        if event.pressed:
            if _begin_stroke():
                _paint_at_screen_position(camera, event.position)
                return AFTER_GUI_INPUT_STOP
            return AFTER_GUI_INPUT_PASS

        if _stroke_active:
            _end_stroke()
            return AFTER_GUI_INPUT_STOP

    if event is InputEventMouseMotion and _stroke_active:
        _paint_at_screen_position(camera, event.position)
        return AFTER_GUI_INPUT_STOP

    return AFTER_GUI_INPUT_PASS


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
    if not _can_paint():
        return
    if _hover_world_position == null:
        return

    var local_position := _current_paint_target.to_local(_hover_world_position as Vector3)
    var uv := _current_paint_target.call("local_to_mask_uv", local_position) as Vector2
    if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
        return

    var color := Color(0.2, 1.0, 0.3, 0.9) if _biomes_panel.mode_option.selected == 0 else Color(1.0, 0.25, 0.25, 0.9)
    var radius_px := maxf(_biomes_panel.get_brush_size() * 8.0, 6.0)
    overlay.draw_arc(_hover_screen_position, radius_px, 0.0, TAU, 48, color, 2.0, true)
    overlay.draw_circle(_hover_screen_position, 2.5, color)


func _build_panel() -> void:
    _panel = VBoxContainer.new()
    _panel.name = PANEL_TITLE

    _biomes_panel = BIOMES_PANEL_SCRIPT.new()
    _biomes_panel.paint_toggled.connect(_on_paint_toggled)
    _biomes_panel.create_mask_requested.connect(_on_create_mask_pressed)
    _biomes_panel.clear_requested.connect(_on_clear_channel_pressed)
    _biomes_panel.channel_selected.connect(_on_mask_channel_selected)
    _panel.add_child(_biomes_panel)

    _terrain_texture_label = Label.new()
    _terrain_texture_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _panel.add_child(_terrain_texture_label)

    _billboard_separator = HSeparator.new()
    _panel.add_child(_billboard_separator)

    _billboard_section = Label.new()
    _billboard_section.text = "Billboards"
    _panel.add_child(_billboard_section)

    _billboard_row = HBoxContainer.new()
    _panel.add_child(_billboard_row)

    _billboard_resolution_option = OptionButton.new()
    for resolution in RESOLUTION_PRESETS:
        _billboard_resolution_option.add_item("%sx%s" % [resolution, resolution], resolution)
    _billboard_resolution_option.selected = 1
    _billboard_row.add_child(_billboard_resolution_option)

    _billboard_output_dir_edit = LineEdit.new()
    _billboard_output_dir_edit.placeholder_text = "res://generated/biomes_billboards"
    _billboard_output_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _billboard_output_dir_edit.text_submitted.connect(_on_billboard_output_dir_text_submitted)
    _billboard_output_dir_edit.focus_exited.connect(_on_billboard_output_dir_focus_exited)
    _billboard_row.add_child(_billboard_output_dir_edit)

    _billboard_output_dir_button = Button.new()
    _billboard_output_dir_button.text = "Choose Output Dir"
    _billboard_output_dir_button.pressed.connect(_on_choose_billboard_output_dir_pressed)
    _billboard_row.add_child(_billboard_output_dir_button)

    _generate_billboards_button = Button.new()
    _generate_billboards_button.text = "Generate Billboards"
    _generate_billboards_button.pressed.connect(_on_generate_billboards_pressed)
    _billboard_row.add_child(_generate_billboards_button)

    _generate_canopy_button = Button.new()
    _generate_canopy_button.text = "Generate Canopy"
    _generate_canopy_button.tooltip_text = "The layer's trees seen from afar: its Far Texture (canopy.res) and far canopy's roof (canopy_roof.res)"
    _generate_canopy_button.pressed.connect(_on_generate_canopy_pressed)
    _billboard_row.add_child(_generate_canopy_button)

    _generate_shadows_button = Button.new()
    _generate_shadows_button.text = "Generate Shadow Meshes"
    _generate_shadows_button.tooltip_text = "Each entry's model simplified, without wind, to cast its shadow alone (shadow.tscn)"
    _generate_shadows_button.pressed.connect(_on_generate_simplified_pressed.bind(Simplified.SHADOW))
    _billboard_row.add_child(_generate_shadows_button)

    _generate_mids_button = Button.new()
    _generate_mids_button.text = "Generate Mid Meshes"
    _generate_mids_button.tooltip_text = "Each entry's model simplified, with its own materials, drawn from Mid LOD Distance (mid.tscn)"
    _generate_mids_button.pressed.connect(_on_generate_simplified_pressed.bind(Simplified.MID))
    _billboard_row.add_child(_generate_mids_button)

    _status_label = _biomes_panel.get("status_label")

    add_control_to_bottom_panel(_panel, PANEL_TITLE)
    _panel.visible = false


func _build_file_dialog() -> void:
    _save_dialog = FileDialog.new()
    _save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
    _save_dialog.access = FileDialog.ACCESS_RESOURCES
    _save_dialog.filters = PackedStringArray(["*.png ; PNG texture"])
    _save_dialog.file_selected.connect(_on_mask_file_selected)
    get_editor_interface().get_base_control().add_child(_save_dialog)

    _billboard_dir_dialog = FileDialog.new()
    _billboard_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
    _billboard_dir_dialog.access = FileDialog.ACCESS_RESOURCES
    _billboard_dir_dialog.dir_selected.connect(_on_billboard_output_dir_selected)
    get_editor_interface().get_base_control().add_child(_billboard_dir_dialog)


func _build_overwrite_dialog() -> void:
    _overwrite_dialog = ConfirmationDialog.new()
    _overwrite_dialog.title = "Generate Billboards"
    _overwrite_dialog.ok_button_text = "Generate"
    _overwrite_dialog.min_size = Vector2i(360, 0)
    _overwrite_dialog.confirmed.connect(_on_overwrite_dialog_confirmed)

    var container := VBoxContainer.new()
    container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _overwrite_dialog.add_child(container)

    var label := Label.new()
    label.text = "Choose what to do with entries that already have billboard output."
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.custom_minimum_size = Vector2(320.0, 0.0)
    container.add_child(label)

    _overwrite_mode_option = OptionButton.new()
    _overwrite_mode_option.fit_to_longest_item = false
    _overwrite_mode_option.add_item("Skip Existing", OVERWRITE_SKIP)
    _overwrite_mode_option.add_item("Overwrite Existing", OVERWRITE_OVERWRITE)
    _overwrite_mode_option.selected = 0
    container.add_child(_overwrite_mode_option)

    get_editor_interface().get_base_control().add_child(_overwrite_dialog)


func _build_clear_channel_dialog() -> void:
    _clear_channel_dialog = ConfirmationDialog.new()
    _clear_channel_dialog.title = "Clear Mask Channel"
    _clear_channel_dialog.ok_button_text = "Clear"
    _clear_channel_dialog.min_size = Vector2i(360, 0)
    _clear_channel_dialog.confirmed.connect(_on_clear_channel_confirmed)

    var label := Label.new()
    label.name = "Message"
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.custom_minimum_size = Vector2(320.0, 0.0)
    _clear_channel_dialog.add_child(label)

    get_editor_interface().get_base_control().add_child(_clear_channel_dialog)


func _refresh_panel_state() -> void:
    if _panel == null:
        return

    var has_target := _current_paint_target != null
    var has_biomes := _current_biomes != null
    _panel.visible = has_target
    # a Biomes growing on a texture of its Terrain3D has no mask to paint
    var terrain_texture_name := _get_terrain_texture_name()
    _biomes_panel.visible = terrain_texture_name.is_empty()
    _terrain_texture_label.visible = not terrain_texture_name.is_empty()
    _terrain_texture_label.text = "Grows on the Terrain3D texture \"%s\" (Terrain Texture in the inspector). Paint that texture on the terrain with Terrain3D's Paint Texture tool - the instances follow when a stroke ends." % terrain_texture_name
    if _biomes_panel != null:
        _biomes_panel.set_controls_enabled(has_target, _billboard_generation_running)
        _biomes_panel.set_mask_label("Mask" if has_biomes else "Grass Mask")
        _biomes_panel.set_selected_channel(_get_current_mask_channel())
    if _billboard_resolution_option != null:
        _billboard_resolution_option.disabled = not has_biomes or _billboard_generation_running
    if _billboard_output_dir_edit != null:
        _billboard_output_dir_edit.editable = has_biomes and not _billboard_generation_running
    if _billboard_output_dir_button != null:
        _billboard_output_dir_button.disabled = not has_biomes or _billboard_generation_running
    if _generate_billboards_button != null:
        _generate_billboards_button.disabled = not has_biomes or _billboard_generation_running
    if _generate_canopy_button != null:
        _generate_canopy_button.disabled = not has_biomes or _billboard_generation_running
    if _generate_shadows_button != null:
        _generate_shadows_button.disabled = not has_biomes or _billboard_generation_running
    if _generate_mids_button != null:
        _generate_mids_button.disabled = not has_biomes or _billboard_generation_running

    if not has_target:
        _biomes_panel.set_status("Select a Biomes node to edit its mask.")
        if _biomes_panel != null:
            _biomes_panel.clear_target_state()
        if _billboard_output_dir_edit != null:
            _billboard_output_dir_edit.text = ""
        _hover_world_position = null
        update_overlays()
        return

    if _billboard_separator != null:
        _billboard_separator.visible = has_biomes
    if _billboard_section != null:
        _billboard_section.visible = has_biomes
    if _billboard_row != null:
        _billboard_row.visible = has_biomes

    if _billboard_generation_running:
        return

    var path := _current_paint_target.call("get_mask_texture_path") as String
    if has_biomes:
        _billboard_output_dir_edit.text = _current_biomes.billboard_output_dir
    if path.is_empty():
        _biomes_panel.set_status("No mask asset yet. Create one to enable 3D painting.")
    else:
        var channel := _get_current_mask_channel()
        _biomes_panel.set_status("Painting %s on %s" % [_channel_name(channel), path])


## the name of the Terrain3D texture the edited Biomes grows on; "" without one
func _get_terrain_texture_name() -> String:
    if _current_biomes == null or _current_biomes.terrain == null \
            or _current_biomes.terrain_texture == Biomes.TERRAIN_TEXTURE_ANYWHERE:
        return ""
    var assets: Resource = _current_biomes.terrain.get("assets")
    var texture: Resource = assets.get_texture(_current_biomes.terrain_texture) if assets != null else null
    return texture.name if texture != null else str(_current_biomes.terrain_texture)


func _on_property_edited(property: String) -> void:
    if property in ["terrain", "terrain_texture"] and _current_biomes != null:
        _refresh_panel_state()


func _can_paint() -> bool:
    if _current_paint_target == null:
        return false
    if not _get_terrain_texture_name().is_empty():
        return false
    if _billboard_generation_running:
        return false
    if not _biomes_panel.is_paint_enabled():
        return false
    if (_current_paint_target.call("get_mask_texture_path") as String).is_empty():
        return false
    return true


func _on_paint_toggled(enabled: bool) -> void:
    if not enabled:
        _hover_world_position = null
        if _stroke_active:
            _end_stroke()
    update_overlays()


func _on_mask_channel_selected(channel: int) -> void:
    if _current_paint_target == null:
        return
    _set_current_mask_channel(channel)
    _refresh_panel_state()


func _on_clear_channel_pressed() -> void:
    if _current_paint_target == null:
        return
    var message := _clear_channel_dialog.get_node("Message") as Label
    if message != null:
        message.text = "Clear %s channel from the current mask? This affects the whole texture." % _channel_name(_get_current_mask_channel())
    _clear_channel_dialog.popup_centered_clamped(Vector2i(380, 120))


func _begin_stroke() -> bool:
    if not _can_paint():
        return false

    _stroke_before_image = _current_paint_target.call("get_mask_image_copy")
    _stroke_working_image = _stroke_before_image.duplicate()
    _stroke_active = true
    _last_painted_pixel = Vector2i(-1, -1)
    return true


func _end_stroke() -> void:
    if not _stroke_active:
        return

    _stroke_active = false
    if _stroke_before_image == null or _stroke_working_image == null:
        return
    if _stroke_before_image.get_data() == _stroke_working_image.get_data():
        _current_paint_target.call("preview_mask_image", _stroke_before_image)
        return

    var undo_redo := get_undo_redo()
    undo_redo.create_action("Paint Biomes Mask")
    undo_redo.add_do_method(_current_paint_target, "set_mask_image", _stroke_working_image, true)
    undo_redo.add_undo_method(_current_paint_target, "set_mask_image", _stroke_before_image, true)
    undo_redo.commit_action()
    _refresh_current_mask_texture.call_deferred()


func _paint_at_screen_position(camera: Camera3D, screen_position: Vector2) -> void:
    if _current_paint_target == null or _stroke_working_image == null:
        return

    var world_position: Variant = _intersect_mask_plane(camera, screen_position)
    if world_position == null:
        return

    var local_position := _current_paint_target.to_local(world_position as Vector3)
    var uv := _current_paint_target.call("local_to_mask_uv", local_position) as Vector2
    if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
        return

    var pixel := Vector2i(
        int(round(uv.x * float(_stroke_working_image.get_width() - 1))),
        int(round(uv.y * float(_stroke_working_image.get_height() - 1)))
    )
    if pixel == _last_painted_pixel:
        return

    _last_painted_pixel = pixel
    var value: float = _biomes_panel.get_paint_value()
    if _current_paint_target.call(
        "paint_mask_circle_on_image",
        _stroke_working_image,
        local_position,
        _biomes_panel.get_brush_size(),
        value,
        _biomes_panel.get_brush_hardness(),
        _biomes_panel.get_brush_opacity()
    ):
        _current_paint_target.call("preview_mask_image", _stroke_working_image)


func _intersect_mask_plane(camera: Camera3D, screen_position: Vector2) -> Variant:
    if _current_paint_target == null:
        return null

    var ray_origin := camera.project_ray_origin(screen_position)
    var ray_direction := camera.project_ray_normal(screen_position)
    var terrain_hit := _intersect_current_target_surface(ray_origin, ray_direction)
    if terrain_hit != null:
        return terrain_hit

    var plane_origin := _current_paint_target.global_transform.origin
    var plane_normal := (_current_paint_target.global_transform.basis.orthonormalized() * Vector3.UP).normalized()
    var denominator := plane_normal.dot(ray_direction)
    if absf(denominator) < 0.0001:
        return null

    var distance := plane_normal.dot(plane_origin - ray_origin) / denominator
    if distance < 0.0:
        return null

    return ray_origin + ray_direction * distance


func _intersect_current_target_surface(ray_origin: Vector3, ray_direction: Vector3) -> Variant:
    # only a TerrainPatch3D of the forest demo was painted on its surface; a Biomes
    # mask is painted on its plane
    return null


func _on_create_mask_pressed() -> void:
    if _current_paint_target == null:
        return
    _save_dialog.current_dir = "res://"
    _save_dialog.current_file = "biomes_mask.png"
    _save_dialog.popup_centered_ratio(0.6)


func _on_mask_file_selected(path: String) -> void:
    if _current_paint_target == null:
        return

    var resolution: int = _biomes_panel.get_resolution()
    if _current_paint_target.call("create_mask_texture_file", path, resolution):
        _pending_mask_path = path
        _biomes_panel.set_status("Importing mask %s" % path)
        _import_and_assign_mask.call_deferred(path)
    else:
        _biomes_panel.set_status("Failed to create mask at %s" % path)


func _on_clear_channel_confirmed() -> void:
    if _current_paint_target == null:
        return
    var before_image := _current_paint_target.call("get_mask_image_copy") as Image
    if before_image == null or before_image.is_empty():
        return
    var after_image := before_image.duplicate()
    _clear_channel_in_image(after_image, _get_current_mask_channel())
    if before_image.get_data() == after_image.get_data():
        return

    var undo_redo := get_undo_redo()
    undo_redo.create_action("Clear Mask Channel")
    undo_redo.add_do_method(_current_paint_target, "set_mask_image", after_image, true)
    undo_redo.add_undo_method(_current_paint_target, "set_mask_image", before_image, true)
    undo_redo.commit_action()
    _refresh_current_mask_texture.call_deferred()
    _refresh_panel_state()


func _import_and_assign_mask(path: String) -> void:
    if _current_paint_target == null:
        return

    await _rescan_filesystem()

    var texture := ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_REPLACE) as Texture2D
    if texture == null:
        _biomes_panel.set_status("Mask saved, but import failed for %s" % path)
        return

    _current_paint_target.call("assign_mask_texture", texture, true)
    _pending_mask_path = ""
    _biomes_panel.set_status("Created mask %s" % path)
    _refresh_panel_state()


func _refresh_current_mask_texture() -> void:
    if _current_paint_target == null:
        return
    var path := _current_paint_target.call("get_mask_texture_path") as String
    if path.is_empty():
        return

    await _rescan_filesystem()

    var texture := ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_REPLACE) as Texture2D
    if texture == null:
        _biomes_panel.set_status("Mask refresh failed for %s" % path)
        return

    _current_paint_target.call("assign_mask_texture", texture, true)
    _refresh_panel_state()


func _on_generate_billboards_pressed() -> void:
    if _current_biomes == null or _billboard_generation_running:
        return
    _apply_billboard_output_dir_from_ui()
    _overwrite_mode_option.selected = 0
    _overwrite_dialog.popup_centered_clamped(Vector2i(360, 120))


func _on_choose_billboard_output_dir_pressed() -> void:
    if _current_biomes == null or _billboard_dir_dialog == null:
        return
    _billboard_dir_dialog.current_dir = _current_biomes.billboard_output_dir if not _current_biomes.billboard_output_dir.is_empty() else "res://"
    _billboard_dir_dialog.popup_centered_ratio(0.7)


func _on_billboard_output_dir_selected(path: String) -> void:
    if _current_biomes == null:
        return
    _set_billboard_output_dir(path)


func _on_billboard_output_dir_text_submitted(_text: String) -> void:
    _apply_billboard_output_dir_from_ui()


func _on_billboard_output_dir_focus_exited() -> void:
    _apply_billboard_output_dir_from_ui()


func _apply_billboard_output_dir_from_ui() -> void:
    if _current_biomes == null or _billboard_output_dir_edit == null:
        return
    _set_billboard_output_dir(_billboard_output_dir_edit.text)


func _set_billboard_output_dir(path: String) -> void:
    if _current_biomes == null:
        return
    var normalized := path.strip_edges()
    if normalized.is_empty():
        normalized = "res://generated/biomes_billboards"
    if not normalized.begins_with("res://"):
        normalized = "res://%s" % normalized.trim_prefix("/")
    normalized = normalized.rstrip("/")
    _current_biomes.billboard_output_dir = normalized
    if _billboard_output_dir_edit != null:
        _billboard_output_dir_edit.text = normalized


func _on_overwrite_dialog_confirmed() -> void:
    if _current_biomes == null or _billboard_generation_running:
        return
    var overwrite_mode := _overwrite_mode_option.get_selected_id()
    _generate_billboards_for_current_biomes.call_deferred(overwrite_mode)


func _generate_billboards_for_current_biomes(overwrite_mode: int) -> void:
    if _current_biomes == null:
        return

    var biomes := _current_biomes
    _billboard_generation_running = true
    _refresh_panel_state()
    _status_label.text = "Generating billboard assets for %s..." % biomes.name

    var generated := 0
    var skipped := 0
    var failed := 0
    var resolution := _billboard_resolution_option.get_selected_id()

    for index in range(biomes.entries.size()):
        var entry := biomes.entries[index]
        var result: Dictionary = await _generate_billboard_for_entry(biomes, entry, index, resolution, overwrite_mode)
        match String(result.get("status", "failed")):
            "generated":
                generated += 1
            "skipped":
                skipped += 1
            _:
                failed += 1

    await _rescan_filesystem()
    if is_instance_valid(biomes):
        biomes.regenerate()
    _billboard_generation_running = false
    _refresh_panel_state()
    _status_label.text = "Billboards: %s generated, %s skipped, %s failed." % [generated, skipped, failed]


func _generate_billboard_for_entry(biomes: Biomes, entry: BiomeScatterEntry, entry_index: int, resolution: int, overwrite_mode: int) -> Dictionary:
    if biomes == null or entry == null:
        return {"status": "failed"}

    var source := _instantiate_billboard_source(entry, entry_index)
    if source.is_empty():
        return {"status": "skipped"}

    var base_dir := "%s/%s/%s" % [
        _get_billboard_output_root(biomes),
        _sanitize_asset_name(biomes.name),
        "%02d_%s" % [entry_index, source["name"]]
    ]
    var png_path := "%s/billboard.png" % base_dir
    var material_path := "%s/billboard_material.tres" % base_dir
    var scene_path := "%s/billboard.tscn" % base_dir
    if _should_skip_billboard_generation(entry, png_path, material_path, scene_path, overwrite_mode):
        source["root"].free()
        return {"status": "skipped"}

    if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base_dir)) != OK:
        source["root"].free()
        return {"status": "failed"}

    var render_result: Dictionary = await _render_billboard_image(source["root"], resolution)
    source["root"].free()
    if render_result.is_empty():
        return {"status": "failed"}

    var image := render_result["image"] as Image
    var quad_size := render_result["quad_size"] as Vector2
    if image == null or image.is_empty() or quad_size == Vector2.ZERO:
        return {"status": "failed"}

    if image.save_png(png_path) != OK:
        return {"status": "failed"}

    var texture := ImageTexture.create_from_image(image)
    if texture == null:
        return {"status": "failed"}

    var material := StandardMaterial3D.new()
    material.resource_name = "%s_billboard_material" % source["name"]
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    material.roughness = 1.0
    material.metallic_specular = 0.0
    material.albedo_texture = texture
    material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
    if ResourceSaver.save(material, material_path) != OK:
        return {"status": "failed"}
    var saved_material := ResourceLoader.load(material_path, "Material", ResourceLoader.CACHE_MODE_REPLACE) as Material
    if saved_material == null:
        return {"status": "failed"}

    var quad_mesh := QuadMesh.new()
    quad_mesh.size = quad_size
    quad_mesh.material = saved_material

    var root := Node3D.new()
    root.name = "%sBillboard" % source["name"].capitalize()

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "Billboard"
    mesh_instance.mesh = quad_mesh
    mesh_instance.position = Vector3(0.0, quad_size.y * 0.5, 0.0)
    root.add_child(mesh_instance)
    mesh_instance.owner = root

    var packed_scene := PackedScene.new()
    if packed_scene.pack(root) != OK:
        root.free()
        return {"status": "failed"}
    root.free()

    if ResourceSaver.save(packed_scene, scene_path) != OK:
        return {"status": "failed"}

    var saved_scene := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
    if saved_scene == null:
        return {"status": "failed"}

    entry.billboard_scene = saved_scene
    if entry.billboard_lod_distance <= 0.0:
        entry.billboard_lod_distance = 60.0
    return {"status": "generated"}


func _on_generate_canopy_pressed() -> void:
    if _current_biomes == null or _billboard_generation_running:
        return
    _apply_billboard_output_dir_from_ui()
    _generate_canopy_for_current_biomes.call_deferred()


## The edited layer's canopies, its trees as a forest is seen from afar (_bake_canopy()): its Far
## Texture on a tile of the terrain's far texture (1 / far_albedo_uv_scale; canopy.res) and its far
## canopy's roof on a tile of far_canopy_tile, with the forest's clumps and gaps (canopy_roof.res) -
## saved with their mipmaps in <output dir>/<layer>/ and set on the layer. Both are toned to the mean
## colour of the roof's tile seen as the Far Texture is (from CANOPY_ELEVATION, no gaps): the ground
## the forest stands on afar and the canopy over it alike, the roof's gaps (from higher) its structure
## and not a darker forest, and the colour of many trees, not of a small tile's few.
func _generate_canopy_for_current_biomes() -> void:
    if _current_biomes == null:
        return
    var biomes := _current_biomes
    var material: Object = biomes.terrain.get("material") if biomes.terrain != null else null
    var uv_scale: Variant = material.get_shader_param("far_albedo_uv_scale") if material != null else null
    var far_tile := 1.0 / (float(uv_scale) if uv_scale != null and float(uv_scale) > 0.0 else FAR_ALBEDO_UV_SCALE_DEFAULT)
    var entries: Array[BiomeScatterEntry] = []
    for entry in biomes.entries:
        if entry != null and entry.probability > 0.0 and (entry.mesh_scene != null or entry.mesh != null):
            entries.append(entry)
    if entries.is_empty():
        _status_label.text = "Canopy: %s has no trees." % biomes.name
        return
    _billboard_generation_running = true
    _refresh_panel_state()
    _status_label.text = "Generating the canopy of %s..." % biomes.name
    var resolution := _billboard_resolution_option.get_selected_id()
    var directory := "%s/%s" % [_get_billboard_output_root(biomes), _sanitize_asset_name(biomes.name)]
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
    var far_path := directory.path_join("canopy.res")
    var roof_path := directory.path_join("canopy_roof.res")
    var colour: Image = await _bake_canopy(biomes, entries, biomes.far_canopy_tile, resolution, CANOPY_ELEVATION, false)
    var far: Image = await _bake_canopy(biomes, entries, far_tile, resolution, CANOPY_ELEVATION, false)
    var roof: Image = await _bake_canopy(biomes, entries, biomes.far_canopy_tile, resolution * CANOPY_ROOF_RESOLUTION,
            CANOPY_ROOF_ELEVATION, true)
    var saved := colour != null and far != null and roof != null
    if saved:
        var target := _image_mean(colour)
        for bake: Array in [[far, far_path], [roof, roof_path]]:
            var image: Image = bake[0]
            var mean := _image_mean(image)
            var toned := image.get_data()
            for index in toned.size():
                toned[index] = clampi(roundi(toned[index] * target[index % 3] / maxf(mean[index % 3], CANOPY_MEAN_MIN)), 0, 255)
            image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGB8, toned)
            image.generate_mipmaps()
            image.compress(Image.COMPRESS_S3TC)
            saved = saved and ResourceSaver.save(ImageTexture.create_from_image(image), bake[1], ResourceSaver.FLAG_COMPRESS) == OK
    await _rescan_filesystem()
    _billboard_generation_running = false
    _refresh_panel_state()
    if not saved or not is_instance_valid(biomes):
        _status_label.text = "Canopy: could not save %s." % directory
        return
    biomes.far_texture = ResourceLoader.load(far_path, "Texture2D", ResourceLoader.CACHE_MODE_REPLACE) as Texture2D
    biomes.far_canopy_texture = ResourceLoader.load(roof_path, "Texture2D", ResourceLoader.CACHE_MODE_REPLACE) as Texture2D
    _status_label.text = "Canopy: %s and %s set on %s." % [far_path.get_file(), roof_path.get_file(), biomes.name]


## A tile [param tile] wide of the layer's [param entries] seen from [param elevation] over the
## horizon [deg], the mean of CANOPY_VIEWS sides (_render_canopy_view()), [param resolution] pixels a side,
## RGB8: a tree a cell of a grid of the spacing, jittered in it (randomly placed, a few left a band
## without one across the tile - stripes from afar), its entry by probability as the server picks
## them; with [param clumps], left out where a forest's density is low (_clump_density()) - its gaps
## and clumps, repeating with the tile. Null when nothing was rendered.
func _bake_canopy(biomes: Biomes, entries: Array[BiomeScatterEntry], tile: float, resolution: int, elevation: float,
        clumps: bool) -> Image:
    var total := 0.0
    for entry in entries:
        total += entry.probability
    # each entry's bounds, unscaled
    var bounds: Dictionary = {}
    for entry in entries:
        var source := _instantiate_billboard_source(entry, biomes.entries.find(entry))
        var found := _compute_scene_bounds(source["root"])
        source["root"].free()
        bounds[entry] = found["aabb"] if bool(found.get("has_bounds", false)) else AABB()
    var rng := RandomNumberGenerator.new()
    rng.seed = biomes.seed
    var waves: Array[Vector3] = []
    for wave: Vector2i in CANOPY_CLUMP_WAVES:
        waves.append(Vector3(wave.x, wave.y, rng.randf() * TAU))
    var side := maxi(1, roundi(tile / biomes.average_spacing))
    var cell := tile / side
    var trees: Array[Dictionary] = []
    for tree in side * side:
        var at := Vector3((tree % side + rng.randf_range(0.2, 0.8)) * cell - tile * 0.5, 0.0,
                (tree / side + rng.randf_range(0.2, 0.8)) * cell - tile * 0.5)
        var pick := rng.randf() * total
        var keep := rng.randf()
        if clumps and keep > _clump_density(waves, at, tile):
            continue
        var entry: BiomeScatterEntry = entries.back()
        for candidate in entries:
            pick -= candidate.probability
            if pick <= 0.0:
                entry = candidate
                break
        var scale := Vector3(rng.randf_range(entry.scale_min.x, entry.scale_max.x),
                rng.randf_range(entry.scale_min.y, entry.scale_max.y), rng.randf_range(entry.scale_min.z, entry.scale_max.z))
        var aabb: AABB = bounds[entry]
        trees.append({"entry": entry, "place": Transform3D(Basis.IDENTITY.rotated(Vector3.UP, rng.randf() * TAU).scaled(scale), at),
                "height": aabb.end.y * scale.y, "radius": maxf(aabb.size.x * scale.x, aabb.size.z * scale.z) * 0.5})
    var views: Array[Image] = []
    for view in CANOPY_VIEWS:
        var image := await _render_canopy_view(biomes, trees, tile, resolution, elevation, TAU * view / CANOPY_VIEWS)
        if image != null:
            views.append(image)
    if views.is_empty():
        return null
    # the views' mean, drawn over each other: the k-th at 1 / (k + 1)
    var viewport := SubViewport.new()
    viewport.size = Vector2i(resolution, resolution)
    viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
    add_child(viewport)
    for index in views.size():
        var layer := TextureRect.new()
        layer.texture = ImageTexture.create_from_image(views[index])
        layer.size = Vector2(resolution, resolution)
        layer.modulate.a = 1.0 / (index + 1)
        viewport.add_child(layer)
    await get_tree().process_frame
    await RenderingServer.frame_post_draw
    var mean := viewport.get_texture().get_image()
    viewport.queue_free()
    mean.convert(Image.FORMAT_RGB8)
    return mean


## An RGB8 image's mean colour
static func _image_mean(image: Image) -> Color:
    var pixel := image.duplicate() as Image
    pixel.resize(1, 1, Image.INTERPOLATE_TRILINEAR)
    return pixel.get_pixel(0, 0)


## The share of a forest's trees standing at [param at] (a tile [param tile] wide): around
## CANOPY_CLUMP_DENSITY, by [param waves] - whole waves across the tile (x, z) at a phase (the third),
## so the clumps and gaps repeat with it
static func _clump_density(waves: Array[Vector3], at: Vector3, tile: float) -> float:
    var wave_sum := 0.0
    for wave: Vector3 in waves:
        wave_sum += sin(TAU * (wave.x * at.x + wave.y * at.z) / tile + wave.z)
    return CANOPY_CLUMP_DENSITY + CANOPY_CLUMP_AMPLITUDE * wave_sum / waves.size()


## A tile of [param trees] seen from [param elevation] over the horizon [deg], from the side [param heading]
## (around Y): straight down on the trees leant away from it - sheared, a point's height moving it
## along the ground - so the ground stays where it is and the tile repeats; a tree is also drawn a
## tile away where its lean or its crown reaches over the tile's side. RGB8, the image's rows along
## +Z (the terrain's v); null when nothing was rendered.
func _render_canopy_view(biomes: Biomes, trees: Array[Dictionary], tile: float, resolution: int, elevation: float,
        heading: float) -> Image:
    var viewport := SubViewport.new()
    viewport.size = Vector2i(resolution, resolution)
    viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
    viewport.msaa_3d = Viewport.MSAA_4X
    viewport.own_world_3d = true
    viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
    add_child(viewport)
    var scene_root := Node3D.new()
    viewport.add_child(scene_root)
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = CANOPY_GAP_COLOR
    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    scene_root.add_child(world_environment)

    var lean := Vector3(sin(heading), 0.0, cos(heading)) / tan(deg_to_rad(elevation))
    var shear := Transform3D(Basis(Vector3.RIGHT, Vector3.UP + lean, Vector3.BACK), Vector3.ZERO)
    var top := 0.0
    for tree: Dictionary in trees:
        var entry: BiomeScatterEntry = tree["entry"]
        var place: Transform3D = tree["place"]
        top = maxf(top, tree["height"])
        var margin: float = tree["height"] * lean.length() + tree["radius"]
        var reach := ceili(margin / tile) + 1
        for dz in range(-reach, reach + 1):
            for dx in range(-reach, reach + 1):
                var at := place.origin + Vector3(dx * tile, 0.0, dz * tile)
                if absf(at.x) > tile * 0.5 + margin or absf(at.z) > tile * 0.5 + margin:
                    continue
                var copy := _instantiate_billboard_source(entry, biomes.entries.find(entry))
                var holder := Node3D.new()
                holder.transform = Transform3D(Basis.IDENTITY, Vector3(dx * tile, 0.0, dz * tile)) * shear * place
                scene_root.add_child(holder)
                holder.add_child(copy["root"])

    # straight down, the image's rows along +Z as the terrain's far texture lays it (its v along Z)
    var camera := Camera3D.new()
    camera.projection = Camera3D.PROJECTION_ORTHOGONAL
    camera.keep_aspect = Camera3D.KEEP_HEIGHT
    camera.size = tile
    camera.near = 0.05
    camera.far = top + 20.0
    camera.position = Vector3(0.0, top + 10.0, 0.0)
    camera.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
    scene_root.add_child(camera)
    camera.current = true

    await get_tree().process_frame
    await RenderingServer.frame_post_draw
    var image := viewport.get_texture().get_image()
    viewport.queue_free()
    if image == null or image.is_empty():
        return null
    image.convert(Image.FORMAT_RGB8)
    return image


func _on_generate_simplified_pressed(kind: Simplified) -> void:
    if _current_biomes == null or _billboard_generation_running:
        return
    _apply_billboard_output_dir_from_ui()
    _generate_simplified_for_current_biomes.call_deferred(kind)


## The edited layer's simplified models of [param kind]: each entry's model of SIMPLIFIED_MIN_TRIANGLES
## or more simplified (_simplify_surface()), its parts where they stand in the model - a shadow mesh
## with a material casting the shadow alone, without wind (_shadow_material()), a mid model with the
## model's own materials; saved as <output dir>/<layer>/<entry>/shadow.tscn or mid.tscn and set as the
## entry's shadow_scene or mid_scene
func _generate_simplified_for_current_biomes(kind: Simplified) -> void:
    if _current_biomes == null:
        return
    var biomes := _current_biomes
    _billboard_generation_running = true
    _refresh_panel_state()
    var made := 0
    var report := PackedStringArray()
    for index in biomes.entries.size():
        var entry := biomes.entries[index]
        if entry == null:
            continue
        var source := _instantiate_billboard_source(entry, index)
        if source.is_empty():
            continue
        var found: Array = []
        _collect_mesh_instances(source["root"], Transform3D.IDENTITY, found)
        var before := 0
        for item: Array in found:
            for surface in (item[0] as MeshInstance3D).mesh.get_surface_count():
                before += (item[0] as MeshInstance3D).mesh.surface_get_array_index_len(surface) / 3
        if before < SIMPLIFIED_MIN_TRIANGLES:
            source["root"].free()
            continue
        var model := Node3D.new()
        model.name = "%s%s" % [String(source["name"]).capitalize().replace(" ", ""), "Shadow" if kind == Simplified.SHADOW else "Mid"]
        var after := 0
        for item: Array in found:
            var source_instance: MeshInstance3D = item[0]
            var mesh := ArrayMesh.new()
            for surface in source_instance.mesh.get_surface_count():
                var simplified: Dictionary = _simplify_surface(source_instance.mesh.surface_get_arrays(surface),
                        SHADOW_SOLID_SHARE if kind == Simplified.SHADOW else MID_SOLID_SHARE,
                        SHADOW_CARD_SHARE if kind == Simplified.SHADOW else MID_CARD_SHARE)
                mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, simplified["arrays"])
                var material: Material = source_instance.get_active_material(surface)
                mesh.surface_set_material(mesh.get_surface_count() - 1,
                        _shadow_material(material, simplified["cards"]) if kind == Simplified.SHADOW else material)
                after += (simplified["arrays"][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
            var part := MeshInstance3D.new()
            part.name = source_instance.name
            part.transform = item[1]
            part.mesh = mesh
            model.add_child(part)
            part.owner = model
        source["root"].free()
        var directory := "%s/%s/%02d_%s" % [_get_billboard_output_root(biomes), _sanitize_asset_name(biomes.name), index, source["name"]]
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
        var path := directory.path_join("shadow.tscn" if kind == Simplified.SHADOW else "mid.tscn")
        var packed := PackedScene.new()
        if packed.pack(model) == OK and ResourceSaver.save(packed, path) == OK:
            var saved := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
            if kind == Simplified.SHADOW:
                entry.shadow_scene = saved
            else:
                entry.mid_scene = saved
            made += 1
            report.append("%s %d -> %d" % [source["name"], before, after])
        model.free()
    await _rescan_filesystem()
    _billboard_generation_running = false
    _refresh_panel_state()
    if is_instance_valid(biomes):
        biomes.regenerate()
    _status_label.text = "%s: %d (%s)." % ["Shadow meshes" if kind == Simplified.SHADOW else "Mid meshes", made, ", ".join(report)]


## The MeshInstance3Ds under [param node] with their transforms relative to it: [instance, transform]
func _collect_mesh_instances(node: Node, parent: Transform3D, found: Array) -> void:
    for child in node.get_children():
        var local: Transform3D = parent * (child as Node3D).transform if child is Node3D else parent
        if child is MeshInstance3D and (child as MeshInstance3D).mesh:
            found.append([child, local])
        _collect_mesh_instances(child, local, found)


## A surface's arrays simplified: {arrays, cards}. Cards (_card_pieces(): many pieces of a few
## triangles) kept [param card_share] of, evenly, each grown about its middle by sqrt(1 / card_share);
## a solid surface to the first of Godot's meshoptimizer LODs within [param solid_share] of its
## triangles. Positions, normals, uvs kept, and tangents - a mid model is lit as the model is.
static func _simplify_surface(source: Array, solid_share: float, card_share: float) -> Dictionary:
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    var vertices: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
    arrays[Mesh.ARRAY_NORMAL] = source[Mesh.ARRAY_NORMAL]
    arrays[Mesh.ARRAY_TANGENT] = source[Mesh.ARRAY_TANGENT]
    arrays[Mesh.ARRAY_TEX_UV] = source[Mesh.ARRAY_TEX_UV]
    var indices: PackedInt32Array = source[Mesh.ARRAY_INDEX]
    var triangles := indices.size() / 3
    var pieces := _card_pieces(vertices, indices)
    var cards := pieces.size() * CARD_TRIANGLES_MAX >= triangles
    var kept := PackedInt32Array()
    if cards:
        var grow := sqrt(1.0 / card_share)
        var seen := 0
        for piece: Array in pieces.values():
            seen += 1
            # evenly: a card where the running share passes a whole one
            if floori(seen * card_share) == floori((seen - 1) * card_share):
                continue
            var used := {}
            var middle := Vector3.ZERO
            for t: int in piece:
                for k in 3:
                    used[indices[t + k]] = true
            for v: int in used:
                middle += vertices[v]
            middle /= used.size()
            for v: int in used:
                vertices[v] = middle + (vertices[v] - middle) * grow
            for t: int in piece:
                kept.append(indices[t])
                kept.append(indices[t + 1])
                kept.append(indices[t + 2])
    else:
        var importer := ImporterMesh.new()
        importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, source)
        importer.generate_lods(SHADOW_NORMAL_MERGE_ANGLE, SHADOW_NORMAL_SPLIT_ANGLE, [])
        kept = indices
        for lod in importer.get_surface_lod_count(0):
            kept = importer.get_surface_lod_indices(0, lod)
            if kept.size() / 3 <= triangles * solid_share:
                break
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_INDEX] = kept
    return {"arrays": arrays, "cards": cards}


## The pieces of a surface: its triangles (their first index) by the piece they belong to, triangles
## sharing a vertex being of one
static func _card_pieces(vertices: PackedVector3Array, indices: PackedInt32Array) -> Dictionary:
    var parent := PackedInt32Array()
    parent.resize(vertices.size())
    for v in vertices.size():
        parent[v] = v
    var find := func(f: Callable, v: int) -> int:
        while not parent[v] == v:
            parent[v] = parent[parent[v]]
            v = parent[v]
        return v
    for t in range(0, indices.size(), 3):
        var a: int = find.call(find, indices[t])
        for k in [1, 2]:
            var b: int = find.call(find, indices[t + k])
            if not a == b:
                parent[b] = a
    var pieces := {}
    for t in range(0, indices.size(), 3):
        var piece: int = find.call(find, indices[t])
        if not pieces.has(piece):
            pieces[piece] = []
        pieces[piece].append(t)
    return pieces


## A shadow mesh's material: unshaded, both sides, without wind; a card's cut out of its texture as
## [param source] cuts it (alpha_scissor_threshold of a shader, or of a BaseMaterial3D)
static func _shadow_material(source: Material, cards: bool) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    if not cards:
        return material
    var texture: Texture2D = null
    var threshold: Variant = null
    if source is BaseMaterial3D:
        texture = (source as BaseMaterial3D).albedo_texture
        threshold = (source as BaseMaterial3D).alpha_scissor_threshold
    elif source is ShaderMaterial:
        texture = (source as ShaderMaterial).get_shader_parameter("albedo_texture") as Texture2D
        threshold = (source as ShaderMaterial).get_shader_parameter("alpha_scissor_threshold")
    material.albedo_texture = texture
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
    material.alpha_scissor_threshold = float(threshold) if threshold != null else SHADOW_ALPHA_SCISSOR_DEFAULT
    return material


func _instantiate_billboard_source(entry: BiomeScatterEntry, entry_index: int) -> Dictionary:
    if entry.mesh_scene != null:
        var instance := entry.mesh_scene.instantiate()
        if instance != null:
            return {
                "root": instance,
                "name": _source_name_from_resource(entry.mesh_scene, "entry_%s" % entry_index)
            }

    if entry.mesh != null:
        var root := Node3D.new()
        var mesh_instance := MeshInstance3D.new()
        mesh_instance.mesh = entry.mesh
        root.add_child(mesh_instance)
        return {
            "root": root,
            "name": _source_name_from_resource(entry.mesh, "entry_%s_mesh" % entry_index)
        }

    return {}


func _should_skip_billboard_generation(entry: BiomeScatterEntry, png_path: String, material_path: String, scene_path: String, overwrite_mode: int) -> bool:
    if overwrite_mode == OVERWRITE_OVERWRITE:
        return false
    if entry.billboard_scene != null and _scene_has_mesh_instances(entry.billboard_scene):
        return true
    return FileAccess.file_exists(png_path) or FileAccess.file_exists(material_path) or FileAccess.file_exists(scene_path)


func _scene_has_mesh_instances(scene: PackedScene) -> bool:
    if scene == null:
        return false
    var instance := scene.instantiate()
    if instance == null:
        return false
    var has_mesh_instances := _node_has_mesh_instances(instance)
    instance.free()
    return has_mesh_instances


func _node_has_mesh_instances(node: Node) -> bool:
    if node is MeshInstance3D:
        return true
    for child in node.get_children():
        var child_node := child as Node
        if child_node == null:
            continue
        if _node_has_mesh_instances(child_node):
            return true
    return false


func _render_billboard_image(source_root: Node, resolution: int) -> Dictionary:
    var bounds := _compute_scene_bounds(source_root)
    if not bool(bounds.get("has_bounds", false)):
        return {}

    var aabb := bounds["aabb"] as AABB
    if aabb.size == Vector3.ZERO:
        return {}

    var quad_size := Vector2(maxf(aabb.size.x, 0.01), maxf(aabb.size.y, 0.01))
    var depth := maxf(aabb.size.z, 0.01)
    var focus := Vector3(0.0, quad_size.y * 0.5, 0.0)
    var offset := Vector3(
        -(aabb.position.x + aabb.size.x * 0.5),
        -aabb.position.y,
        -(aabb.position.z + aabb.size.z * 0.5)
    )

    var viewport := SubViewport.new()
    viewport.name = "__billboard_viewport"
    viewport.size = Vector2i(resolution, resolution)
    viewport.transparent_bg = true
    viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
    viewport.msaa_3d = Viewport.MSAA_4X
    viewport.use_hdr_2d = false
    viewport.own_world_3d = true
    add_child(viewport)

    var scene_root := Node3D.new()
    viewport.add_child(scene_root)

    var holder := Node3D.new()
    holder.position = offset
    scene_root.add_child(holder)
    holder.add_child(source_root)

    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(1.0, 1.0, 1.0, 1.0)
    environment.ambient_light_energy = 0.85

    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    scene_root.add_child(world_environment)

    var key_light := DirectionalLight3D.new()
    key_light.light_energy = 1.35
    key_light.rotation_degrees = Vector3(-42.0, -25.0, 0.0)
    scene_root.add_child(key_light)

    var fill_light := DirectionalLight3D.new()
    fill_light.light_energy = 0.6
    fill_light.rotation_degrees = Vector3(-20.0, 150.0, 0.0)
    scene_root.add_child(fill_light)

    var camera := Camera3D.new()
    camera.projection = Camera3D.PROJECTION_ORTHOGONAL
    camera.keep_aspect = Camera3D.KEEP_HEIGHT
    camera.size = maxf(quad_size.x, quad_size.y) * BILLBOARD_PADDING
    camera.near = 0.05
    camera.far = maxf(depth + quad_size.y + 20.0, 100.0)
    camera.position = Vector3(0.0, focus.y, depth + maxf(quad_size.x, quad_size.y) * 2.0 + 2.0)
    scene_root.add_child(camera)
    camera.current = true
    camera.look_at_from_position(camera.position, focus, Vector3.UP)

    await get_tree().process_frame
    await RenderingServer.frame_post_draw

    var image := viewport.get_texture().get_image()
    viewport.queue_free()
    if image == null or image.is_empty():
        return {}
    if image.is_compressed():
        image.decompress()
    if image.get_format() != Image.FORMAT_RGBA8:
        image.convert(Image.FORMAT_RGBA8)
    image.fix_alpha_edges()

    var alpha_rect := _find_image_alpha_rect(image)
    if alpha_rect.size.x <= 0 or alpha_rect.size.y <= 0:
        return {}
    var world_per_pixel := camera.size / float(resolution)
    var cropped_size := alpha_rect.size
    image = image.get_region(alpha_rect)
    return {
        "image": image,
        "quad_size": Vector2(
            maxf(float(cropped_size.x) * world_per_pixel, 0.01),
            maxf(float(cropped_size.y) * world_per_pixel, 0.01)
        )
    }


func _compute_scene_bounds(root: Node) -> Dictionary:
    var state := {
        "has_bounds": false,
        "min": Vector3.ZERO,
        "max": Vector3.ZERO
    }
    _append_scene_bounds(root, Transform3D.IDENTITY, state)
    if not state["has_bounds"]:
        return {"has_bounds": false}

    var min_point: Vector3 = state["min"]
    var max_point: Vector3 = state["max"]
    return {
        "has_bounds": true,
        "aabb": AABB(min_point, max_point - min_point)
    }


func _append_scene_bounds(node: Node, parent_transform: Transform3D, state: Dictionary) -> void:
    var local_transform := parent_transform
    var node_3d := node as Node3D
    if node_3d != null:
        local_transform = parent_transform * node_3d.transform

    var mesh_instance := node as MeshInstance3D
    if mesh_instance != null and mesh_instance.mesh != null:
        var mesh_aabb := mesh_instance.mesh.get_aabb()
        for corner in _aabb_corners(mesh_aabb):
            var point := local_transform * corner
            if not state["has_bounds"]:
                state["has_bounds"] = true
                state["min"] = point
                state["max"] = point
            else:
                state["min"] = Vector3(
                    minf(state["min"].x, point.x),
                    minf(state["min"].y, point.y),
                    minf(state["min"].z, point.z)
                )
                state["max"] = Vector3(
                    maxf(state["max"].x, point.x),
                    maxf(state["max"].y, point.y),
                    maxf(state["max"].z, point.z)
                )

    for child in node.get_children():
        var child_node := child as Node
        if child_node == null:
            continue
        _append_scene_bounds(child_node, local_transform, state)


func _aabb_corners(aabb: AABB) -> Array[Vector3]:
    var position := aabb.position
    var size := aabb.size
    return [
        position,
        position + Vector3(size.x, 0.0, 0.0),
        position + Vector3(0.0, size.y, 0.0),
        position + Vector3(0.0, 0.0, size.z),
        position + Vector3(size.x, size.y, 0.0),
        position + Vector3(size.x, 0.0, size.z),
        position + Vector3(0.0, size.y, size.z),
        position + size
    ]


func _find_image_alpha_rect(image: Image, alpha_threshold: float = 0.01) -> Rect2i:
    var width := image.get_width()
    var height := image.get_height()
    var min_x := width
    var min_y := height
    var max_x := -1
    var max_y := -1

    for y in range(height):
        for x in range(width):
            if image.get_pixel(x, y).a <= alpha_threshold:
                continue
            min_x = mini(min_x, x)
            min_y = mini(min_y, y)
            max_x = maxi(max_x, x)
            max_y = maxi(max_y, y)

    if max_x < min_x or max_y < min_y:
        return Rect2i()
    return Rect2i(min_x, min_y, (max_x - min_x) + 1, (max_y - min_y) + 1)


func _source_name_from_resource(resource: Resource, fallback: String) -> String:
    if resource == null:
        return _sanitize_asset_name(fallback)
    if not resource.resource_path.is_empty():
        return _sanitize_asset_name(resource.resource_path.get_file().get_basename())
    if not resource.resource_name.is_empty():
        return _sanitize_asset_name(resource.resource_name)
    return _sanitize_asset_name(fallback)


func _sanitize_asset_name(value: String) -> String:
    var result := ""
    for character in value.to_lower():
        var code := character.unicode_at(0)
        var is_lower := code >= 97 and code <= 122
        var is_digit := code >= 48 and code <= 57
        if is_lower or is_digit:
            result += character
        elif character == "_" or character == "-":
            result += character
        else:
            result += "_"

    result = result.strip_edges()
    while result.contains("__"):
        result = result.replace("__", "_")
    result = result.trim_prefix("_").trim_suffix("_")
    if result.is_empty():
        return "billboard"
    return result


func _get_billboard_output_root(biomes: Biomes) -> String:
    if biomes == null:
        return "res://generated/biomes_billboards"
    var root := biomes.billboard_output_dir.strip_edges()
    if root.is_empty():
        return "res://generated/biomes_billboards"
    return root.rstrip("/")


func _rescan_filesystem() -> void:
    var filesystem := get_editor_interface().get_resource_filesystem()
    filesystem.scan()
    await filesystem.filesystem_changed


func _channel_name(channel: int) -> String:
    match channel:
        Biomes.MaskChannel.RED:
            return "Red"
        Biomes.MaskChannel.GREEN:
            return "Green"
        Biomes.MaskChannel.BLUE:
            return "Blue"
        Biomes.MaskChannel.ALPHA:
            return "Alpha"
        Biomes.MaskChannel.LUMINANCE:
            return "Luminance"
    return "Unknown"


func _get_current_mask_channel() -> int:
    if _current_biomes != null:
        return int(_current_biomes.mask_channel)
    if _current_paint_target != null:
        if _current_paint_target.has_method("get_mask_paint_channel"):
            return int(_current_paint_target.call("get_mask_paint_channel"))
        return int(_current_paint_target.get("grass_mask_channel"))
    return 0


func _set_current_mask_channel(channel: int) -> void:
    var clamped_channel := clampi(channel, 0, 4)
    if _current_biomes != null:
        _current_biomes.mask_channel = clamped_channel
        return
    if _current_paint_target != null:
        if _current_paint_target.has_method("set_mask_paint_channel"):
            _current_paint_target.call("set_mask_paint_channel", clamped_channel)
            return
        _current_paint_target.set("grass_mask_channel", clamped_channel)


func _clear_channel_in_image(image: Image, channel: int) -> void:
    for y in range(image.get_height()):
        for x in range(image.get_width()):
            var color := image.get_pixel(x, y)
            match channel:
                Biomes.MaskChannel.RED:
                    color.r = 0.0
                Biomes.MaskChannel.GREEN:
                    color.g = 0.0
                Biomes.MaskChannel.BLUE:
                    color.b = 0.0
                Biomes.MaskChannel.ALPHA:
                    color.a = 0.0
                Biomes.MaskChannel.LUMINANCE:
                    color.r = 0.0
                    color.g = 0.0
                    color.b = 0.0
            image.set_pixel(x, y, color)
