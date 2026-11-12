# GodotFab Unreal commandlet

`UUnrealToGodotCommandlet` is a small `UCommandlet` that drives the
[UnrealToGodot](https://www.fab.com/) exporter plugin without the editor UI. The
Godot addon runs it through `UnrealEditor-Cmd` to convert an installed Fab pack into
a Godot project (meshes as `.glb`, materials as `.tres`, textures as `.png`, the map
as `.tscn`).

```
addons/godotfab/unreal/
  UnrealToGodotCommandlet/UnrealToGodotCommandlet.h    commandlet source (copied into the plugin)
  UnrealToGodotCommandlet/UnrealToGodotCommandlet.cpp
  install_commandlet.sh                                 copies the sources + rebuilds the plugin
```

## Installing (rebuilds the plugin)

Requirements: an installed Unreal Engine 5.8 (Linux), a project that contains the
`UnrealToGodot` plugin in `Plugins/UnrealToGodot/` (sources included), `dotnet` on the
`PATH` (UnrealBuildTool uses it).

```sh
addons/godotfab/unreal/install_commandlet.sh "<engine_dir>" "<project>/<Project>.uproject"
```

The script

1. copies `UnrealToGodotCommandlet.{h,cpp}` into
   `<project>/Plugins/UnrealToGodot/Source/UnrealToGodot/Public/`,
2. backs up `Plugins/UnrealToGodot/Binaries` to `Binaries.bak-<timestamp>` (one backup
   is kept),
3. runs `Engine/Build/BatchFiles/Linux/Build.sh UnrealEditor Linux Development
   -Project=<uproject> -TargetType=Editor -Progress -NoHotReloadFromIDE`,
4. restores the backup if the build fails, and finally checks that
   `libUnrealEditor-UnrealToGodot.so` contains the string `UnrealToGodotCommandlet`
   (that is also how the addon's "Check Unreal setup" verifies the install).

It also applies one minimal, idempotent patch to the plugin's own
`GodotScene.cpp` (the original is kept as `GodotScene.cpp.godotfab-orig`): in
`GodotExporter::DoMeshExport` the line `if (ShowOptions)` becomes
`if (ShowOptions && !FApp::IsUnattended())`. The exporter opens the GLTF
export-options window for the first mesh; commandlets have no Slate application,
so that call asserts (`CurrentBaseApplication.IsValid()`). With the guard the
options come from the saved defaults (`[/Script/GLTFExporter.GLTFExportOptions]` in
`Saved/Config/LinuxEditor/EditorPerProjectUserSettings.ini`) when running
unattended; the editor UI flow is unchanged.

A second one-line patch (same script, same backup file) fixes a converter bug that
also affects exports made from the editor UI: in the prefab writer
(`GodotScene.cpp`, `std::string TransformText = GenerateTransformText( TC );`) the
prefab's own mesh `CollisionShape3D` received the world transform of the instance
the prefab was generated from, so collisions were offset twice in the scene. The
patched line writes no transform for shapes owned by the prefab root
(`Shape->Owner == Prefab`); child primitives (`Box0`, `Capsule0`…) keep their local one.

With `-Map` the commandlet also spawns, in a grid 20 m beside the level, the meshes under
`-ContentPath` that no component of the level uses: maps of game templates spawn their
characters and weapons from Blueprints at run time, so the level alone misses them (and,
with the skeletal meshes, every animation). `-MapOnly` turns this off.

Patch 4 (`UTXModule.cpp`): `FixSkeletalMeshBoneInfluences` called
`USkeletalMesh::GetLODInfoArray()`, a shim deprecated since UE 5.5 that fills a
`thread_local` array with `SetNumUninitialized(N)` followed by N `Add`s. The array keeps N
garbage entries, and the next call destroys them, so a level with several skeletal meshes
crashed (SIGSEGV in `DestructItems<FSkeletalMeshVertexAttributeInfo>`). The patched loop reads
`GetLODNum()`/`GetLODInfo(i)`, which also makes the 4-bone influence limit actually stick.

Patch 5 (`BaseScene.cpp`): `ConvertRVTTextures` read `StreamingTexture->Texture` of each
Runtime Virtual Texture volume without a null check; a volume whose streaming texture was never
built (Medieval Village's landscape) crashed the export. Such volumes are skipped.

Patches 6 to 11 fix converter output that Godot refuses or renders wrong (all found on
the Medieval Village; each is marked `// GodotFab: …` in the source):

- **6, missing collision shape** (`GodotScene.cpp`): a mesh collider whose mesh has no
  convex hulls nor the collision LOD wrote no `ConcavePolygonShape3D`, but the
  `CollisionShape3D` node still referenced it. Godot refuses the prefab ("Invalid
  parameter"), and the editor can't open any scene that instances it ("Error while
  loading file"). The node is now skipped when no shape was written.
- **7, float `#if`** (`GodotScene.cpp`): `FixCustomExpressionCode` turns `#if X` into
  `#if 0//X`, then `normalizeNumbers` makes it `#if 0.0`. Godot's preprocessor only takes
  integers and rejects the whole shader ("Unknown character '#'"). It is put back to `#if 0`.
- **8, bool parameter names** (`GodotScene.cpp`): static bool parameters were written with
  the raw Unreal name (`Level 1 Wind`) while the material used the sanitized one, so the
  uniform didn't compile ("Expected a ';'"). `GenerateBoolParameterNode` sanitizes the name.
- **9, hidden in game** (`ExportToUnity.cpp`): meshes were exported when visible in the
  editor, including actors marked *Actor Hidden In Game* (179 blockout cubes around the
  village) and meshes with a *Volume*-domain material (local volumetric fog boxes, drawn
  as fog in Unreal). Both are skipped.
- **10, light units** (`GodotScene.cpp`): the sun was written ×10000 and point/spot/rect
  lights ×1000 with `light_energy = 16` (a 12000 lux sun became 120 million lux). With
  physical light units Godot uses Unreal's units (lux, lumens), so they are written 1:1.
- **11, Custom expression output type** (`GodotScene.cpp`): Unreal Custom inputs take the
  connected type and HLSL truncates on `return InValue;` (a float4 into a float3 output,
  Medieval Village's `MakePreciseV3`). Godot refuses `output0 = InValue;` ("Invalid
  arguments to operator '='"), and its shading language has no `vec3(vec4)` constructor.
  Exactly `output0 = <Input>;` is rewritten with a swizzle (`InValue.xyz`) when the input is
  a wider vector than the declared output.
- **12, stable UIDs** (`BaseScene.cpp`, `GodotScene.cpp`): resource UIDs were the hash of
  the file's absolute path, output folder included, so exporting elsewhere (or moving the
  project) changed every UID and every reference, and a reimport rewrote every `.import`
  (Godot recompressed every texture). The paths are hashed relative to the output folder
  (`GodotFabStableKey`). Checked by exporting FPS_Weapon_Bundle into two folders: same UIDs,
  377 of 388 files byte-identical. The other 11 are `.glb` files that differ in 2 bytes,
  from the glTF exporter itself.
- **13, Nanite fallback mesh** (`GodotScene.cpp`): `OnExportBegin` turns on the glTF option
  `bExportSourceModel` (for Metahumans) and saves it to the user's config, so every Nanite
  static mesh was written at full resolution, ignoring the default coarse-mesh option.
  Medieval Village's `SM_IcelandicTerrain_High` came out with 2 million triangles (216 MB)
  instead of the 11,929 of its fallback mesh, with 165 instances in the level. With SDFGI on,
  the Godot editor crashed opening the level ("Vulkan device was lost", amdgpu ring
  timeout). Nanite static meshes now export their render data (the fallback mesh, 380 KB,
  same bounds) unless `-NaniteOriginal` is given.
- **14, AppendVector overflow** (`GodotScene.cpp`): output 0 of an Unreal vector parameter is
  RGB (float3), but it is wired to output 0 of Godot's `Vec4Parameter`, a vec4. Appending
  the parameter's alpha (Medieval Village's landscape material) generated
  `vec4(input0, input1)` with a vec4 and a float, which Godot refuses. Unreal never appends
  past 4 components, so input A is swizzled (`input0.xyz`) when the inputs add up to more.
- **15, unique node names** (`GodotScene.cpp`): nodes are named after Unreal actor labels,
  which can repeat (Medieval Village: 1116 root nodes, e.g. two `PlayerStart`). Godot renamed
  them on load and the editor logged "Attempting to parent and popup a dialog that already
  has a parent" 1525 times. Repeated sibling names get `_2`, `_3`... before the level is
  written.
- **16, dangling shader connections** (`GodotScene.cpp`): an expression whose output is not
  used gets no shader node (ID -1), but the connections into it were still written, and
  Godot logged `Condition "!nodes.has(p_to_node)" is true` for each (4 Medieval Village
  materials). Connections with a negative node ID are skipped.
- **17, unlit emissive** (`GodotScene.cpp`): Unreal Unlit emissive is in nits and is exposed
  by the camera, but it was written to ALBEDO of an unshaded shader, which Godot never
  multiplies by the camera exposure (physical light units). The Medieval Village candle
  flames (IntensityMult 6000) came out ~600x too bright, as big white glowing blobs. Unlit
  emissive now goes to EMISSION as is (also nits, exposed by Godot), with a black albedo,
  zero specular, `specular_disabled` and `ambient_light_disabled`.
- **18, vector expression types and local bounds** (`GodotScene.cpp`): the type evaluator
  falls back to the widest input, so input-less vector expressions (LocalPosition, local
  bounds, ObjectPositionWS, ActorPositionWS, ...) and BlackBody were typed float. A Subtract
  of LocalPosition became a FloatOp on `.x`, and a QualitySwitch of BlackBody kept only `.x`
  (the candle flames lost their vertical gradient and their color). These are typed vec3
  now. PreSkinnedLocalBounds/ObjectLocalBounds were a fixed 0..100 cm box; they now use the
  bounds of a static mesh that uses the material (or its base material).
- **19, float textures as EXR** (`ExportToUnity.cpp`): RGBA16F/RGBA32F/R16F textures went
  through `FColor` with sRGB conversion into 8-bit PNG, clamping them to 0..1. Pivot Painter
  position textures (Spruce Forest `*_PIV`) kept 27 distinct pixels out of 1590, every
  branch pivot sat at the origin and the wind stretched the trees. They are saved as linear
  EXR now; GodotFab imports `.exr` lossless without mipmaps.
- **20, nested material function instances** (`GodotScene.cpp`): shader nodes, connections
  and the processing history were keyed by (expression, immediate function call). A call
  inside a material function is a single object, so when the outer function is used several
  times its nested calls collapsed into one node set. Spruce Forest calls `PN_WindAnimation`
  once per wind level (trunk, branch, leaf) and every level read the same Pivot Painter pivot:
  the leaves turned about the wrong point and half of each tree looked empty. Each (parent
  call, nested call) pair now gets its own transient copy of the call. Calls at the
  material's root keep their object, so materials without nested functions are unchanged.
- **21, Clamp mode and trig period** (`GodotScene.cpp`): every Clamp was written as
  `clamp(x, Min, Max)`, ignoring "Clamp Min"/"Clamp Max". Pivot Painter 2's extent decode is
  Clamp Min 8 with the unused Max left at 1, so the extent was always 1 cm: each wind level
  swung its branches rigidly (lower branches far, the top barely). The unused bound is now
  ±1e20. Sine/Cosine/Tangent ignored `Period` (Unreal computes `f(x * 2π / Period)`, default
  1), so Spruce Forest's `WindDirection` barely turned the wind and `PN_Bending` (period 3)
  oscillated at the wrong rate; those nodes are now expressions with the scale. GodotFab's
  importer also fixes Clamp Min in exports from an unpatched plugin.

After the export the commandlet also writes `godotfab_nearest_textures.txt`: every loaded
texture whose Unreal filter is Nearest (package path without `/Game/`). The exporter writes
every Godot texture parameter with linear filtering; Pivot Painter textures (one value per
branch, the parent index in the alpha bits) then blend neighbouring texels where UV2 is a
hair off the texel center, and Spruce Forest's low trees threw their lower branches off the
trunk. GodotFab sets the parameters that receive those textures to nearest.

It also writes `godotfab_opacity_textures.txt`: for every masked material, the texture
channel that feeds Opacity Mask and the clip value (`<texture>\t<R|G|B|A|RGB>\t<clip>`),
found with `UMaterial::RecursiveGetExpressionChain` (the public `GetTexturesInPropertyChain`
does not follow Material Attributes). Mipmaps average the opacity below the clip value and
alpha tested foliage loses its leaves at a distance. GodotFab imports those textures with
`mipmaps/preserve_alpha_test_coverage` at the clip value; when the opacity is in R, G or B
(European Beech's `Mask` uses R), that channel is swapped with alpha on import and the two
output ports of the shader's texture nodes are swapped back.

World Partition maps (`*_WP`, Megascans samples) keep their actors in
`__ExternalActors__`, which `LoadMap` does not load: the commandlet loads every actor of
the world with an `FLoaderAdapterShape` covering the whole world (the editor's "Load All").
Without it the exported scene had only the WorldSettings and volumes.

The commandlet runs as a client (`IsClient = true`): with `GIsClient` false,
`FRendererModule::AllocateScene` gives every world an `FNULLSceneInterface`, and any
skeletal mesh in the map (or spawned for the pack) asserts in `SkeletalRenderGPUSkin.cpp`
("Scene cannot be null when creating a SkeletalMeshObject").

After the export the commandlet rewrites `WorldEnvironment.tscn`, which the plugin
writes from a fixed template (a bright procedural sky as background and ambient light,
no fog), from the level itself: a SkyLight keeps the sky (intensity scaled by the
SkyLight's); without one there is no ambient or sky light, as in Unreal. The
ExponentialHeightFog becomes Godot fog (density × 0.1: Unreal's is per 1000 cm,
Godot's per metre; inscattering colour; height falloff) plus volumetric fog when it is
enabled (albedo, emissive, scattering distribution, distance). The unbound
PostProcessVolume's AO radius becomes `ssao_radius`, and the tonemapper is ACES. The
fog light energy (0.25) was calibrated against the UndergroundTunnel screenshots.

It also rewrites `CameraAttributes.tres` (the plugin copies a template with ISO 600)
from the unbound PostProcessVolume with the highest priority (Unreal's defaults
without one). Unreal's EV100 is `log2(N² × shutter × 100 / ISO)` with the physical
camera (0 without it) minus the exposure compensation. Godot's
`CameraAttributesPractical` assumes f/16 and 1/100 s, so the same exposure is
`exposure_sensitivity = 100 × 2^(log2(25600) − EV100)`. Manual exposure stays manual;
histogram/basic exposure becomes Godot's auto exposure over the same EV range. Godot
doesn't apply the exposure to the volumetric fog emission (Unreal does), so the
emissive is multiplied by `1 / (1.2 × 2^EV100)`. Medieval Village: manual, ISO 100,
1/60 s, f/4, bias +1 → EV100 8.9 → ISO 5333.

A third patch fixes nested parent paths: `GenerateParentName` walked from the node
up to the root appending each name, so a node two levels deep got
`parent="StaticMesh/Actor"` instead of `parent="Actor/StaticMesh"`, and prefab
instances used only their direct parent's name. Godot drops those nodes ("Parent
path ... has vanished"). The loop now prepends each name (marked
`// GodotFab: parent path order`) and instances use `GenerateParentName( GO )`.

The actor rotation the exporter performs before writing the scene
(`AExportActor::RotateActorsForExport`) goes through `GEditor->ApplyDeltaToActor`,
which asserts in commandlets (`GLevelEditorModeTools()`). The commandlet disables it
(`DoRotateOnExport = false`) and performs the same rotation with the static
`FActorElementEditorViewportInteractionCustomization::ApplyDeltaToActor` about the
world origin, mirroring the plugin's sequence: prepare, detach, rotate, export,
rotate back. No plugin file is modified for that.

A full rebuild of the plugin took 19 min (1140 s) on a 16-core machine with UE 5.8.4;
an incremental rebuild after touching only the commandlet takes 35 s to 4 min. The
engine itself is not recompiled.

## Running

```sh
"<engine_dir>/Engine/Binaries/Linux/UnrealEditor-Cmd" "<project>/<Project>.uproject" \
  -run=UnrealToGodot.UnrealToGodot \
  -ContentPath=/Game/<Pack>/<Folder> \
  -Map=/Game/<Pack>/<Folder>/Maps/<Map> \
  "-Output=/abs/path/to/output/" \
  -unattended -nopause -nosplash -AllowCommandletRendering \
  -log "-abslog=/abs/path/to/convert.log"
```

Note the commandlet name: the plugin module loads in the `PostEngineInit` phase, which
is after the engine looks up the commandlet class, so a plain `-run=UnrealToGodot`
fails with "looked like a commandlet, but we could not find the class". The
`Module.Class` form (`-run=UnrealToGodot.UnrealToGodot`, the engine appends
`Commandlet`) makes the engine load the module first.

### Arguments

| Argument | Meaning |
| --- | --- |
| `-Output=<dir>` | required; created if missing, a trailing `/` is added |
| `-Map=<package path>` | load this map (`/Game/.../Maps/Overview`) and export it as is |
| `-ContentPath=<package path>[,<package path>…]` | one or more folders (packs such as Megascans samples install several top-level folders). Without `-Map`: create an empty map and spawn one actor per `StaticMesh`/`SkeletalMesh` under these folders, in a grid spaced by the mesh bounds. The scene is named after the last folder (`VOL2_Laundry.tscn`) |
| `-SkinnedAsStatic` | export skeletal meshes as static meshes (default: skinned) |
| `-NaniteOriginal` | export the original Nanite mesh instead of the coarse one |
| `-NoTextures` | do not write textures |
| `-NoPhysics` | do not export collision |
| `-NoLandscapes` | do not convert landscapes. By default the commandlet runs the plugin's *ConvertLandscapesToStaticMeshes* action first, a manual menu step in the editor. Without it, landscapes are not exported at all (Medieval Village had no ground). It edits the landscape materials in memory only: autosave is off and the commandlet saves nothing |

Engine flags: `-unattended` (dialogs return their default, the exporter pops an
"Export complete" dialog at the end), `-nopause`, `-nosplash`,
`-AllowCommandletRendering` (the exporter bakes materials and reads textures on the
GPU; use `-NullRHI` only if there is no usable GPU, texture baking will then fail),
`-abslog=<file>` for a predictable log location.

### Verified command line

Tested on 2026-11-06 with UE 5.8.4 (installed Linux build), a Blueprint-only
project and the Fab pack `/Game/Laundromat/VOL2_Laundry`:

```sh
"<engine_dir>/Engine/Binaries/Linux/UnrealEditor-Cmd" \
  "<project_dir>/<Project>.uproject" \
  -run=UnrealToGodot.UnrealToGodot \
  -ContentPath=/Game/Laundromat/VOL2_Laundry \
  -Map=/Game/Laundromat/VOL2_Laundry/Maps/Overview \
  "-Output=/path/to/export_test/" \
  -unattended -nopause -nosplash -AllowCommandletRendering \
  -log "-abslog=/path/to/convert.log"
```

Map mode: exit 0 after 68 s (first run after a fresh DDC took ~5 min because of
Nanite/static-mesh builds), 163 nodes in `Overview.tscn`, 138 `.glb`, 140 `.tscn`
(1 map + `Prefabs/*.tscn`), 86 `.png`, 61 `.tres`, 2.8 GB. The same command without
`-Map` (meshes mode) writes `VOL2_Laundry.tscn` with one actor per mesh asset.
`-AllowCommandletRendering` worked directly on a machine with a GPU; `-NullRHI` was
not needed.

### Results

* exit code 0, last log line `LogTemp: Display: GodotFab: export finished`,
  `<Output>/godotfab_done.txt` (`scene=<relative .tscn path>`, `world=`, `map=`,
  `content=` lines), `<Output>/project.godot`, `<Output>/<Map>.tscn`
  (or `<Folder>.tscn` in meshes mode), `Meshes/*.glb`, `Materials/*.tres`,
  `Textures/*.png` under the pack's folder structure.
* exit code 1 and `GodotFab: export failed: <reason>` on any failure (bad arguments,
  map not found, no meshes under the content path, exporter wrote no project/scene).

### Log lines the addon parses for progress

```
LogTemp: GodotFab: Loading Mesh /Game/Pack/Meshes/SM_Foo.SM_Foo (3/120)     meshes mode only
LogTemp: Processing Materials ( 12 / 191 )
LogTemp: Writing Mesh /abs/out/Pack/Meshes/SM_Foo.glb (3/540)
LogTemp: Display: GodotFab: export finished
LogTemp: Error: GodotFab: export failed: <reason>
```
