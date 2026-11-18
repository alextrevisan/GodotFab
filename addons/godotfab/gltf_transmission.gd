@tool
extends GLTFDocumentExtension
## Makes the glass of an imported glTF see-through. Glass comes as an opaque
## material with the KHR_materials_transmission extension (what Blender writes
## for a Transmission weight), which Godot does not read: the glass imports
## solid. Such a material becomes alpha blended, letting through as much light
## as its base color does: clear glass nearly all, dark glass nearly none.

const EXTENSION := "KHR_materials_transmission"
## Clear glass keeps this much of its surface, or it would vanish.
const MIN_ALPHA := 0.12


func _get_supported_extensions() -> PackedStringArray:
	return PackedStringArray([EXTENSION])


func _import_post_parse(state: GLTFState) -> Error:
	var definitions = state.json.get("materials", [])
	var materials := state.get_materials()
	for i in min(materials.size(), definitions.size()):
		if not definitions[i] is Dictionary or not materials[i] is BaseMaterial3D:
			continue
		var factor := transmission_of(definitions[i])
		if factor > 0.0:
			apply(materials[i], factor)
	return OK


## The transmissionFactor of a glTF material definition, 0 without the extension.
static func transmission_of(definition: Dictionary) -> float:
	var extensions = definition.get("extensions", {})
	if not extensions is Dictionary or not extensions.get(EXTENSION) is Dictionary:
		return 0.0
	return float(extensions[EXTENSION].get("transmissionFactor", 0.0))


## Blends the material by what gets through it: the transmission factor times
## the brightness of the base color, which tints the transmitted light.
static func apply(material: BaseMaterial3D, factor: float) -> void:
	var color := material.albedo_color.srgb_to_linear()
	var alpha: float = max(MIN_ALPHA, 1.0 - factor * (color.r + color.g + color.b) / 3.0)
	if alpha >= 1.0:
		return
	material.albedo_color.a *= alpha
	if material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
