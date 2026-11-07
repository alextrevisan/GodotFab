# GodotFab Unreal commandlet

`UUnrealToGodotCommandlet` is a small `UCommandlet` that drives the
[UnrealToGodot](https://www.fab.com/) exporter plugin without the editor UI. The
Godot addon runs it through `UnrealEditor-Cmd` to convert an installed Fab pack into
a Godot project (meshes as `.glb`, materials as `.tres`, textures as `.png`, the map
as `.tscn`).

```
unreal/
  UnrealToGodotCommandlet/UnrealToGodotCommandlet.h    commandlet source (copied into the plugin)
  UnrealToGodotCommandlet/UnrealToGodotCommandlet.cpp
  install_commandlet.sh                                 copies the sources + rebuilds the plugin
```

## Installing (rebuilds the plugin)

Requirements: an installed Unreal Engine 5.8 (Linux), a project that contains the
`UnrealToGodot` plugin in `Plugins/UnrealToGodot/` (sources included), `dotnet` on the
`PATH` (UnrealBuildTool uses it).

```sh
unreal/install_commandlet.sh "<engine_dir>" "<project>/<Project>.uproject"
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

Engine flags: `-unattended` (dialogs return their default, the exporter pops an
"Export complete" dialog at the end), `-nopause`, `-nosplash`,
`-AllowCommandletRendering` (the exporter bakes materials and reads textures on the
GPU; use `-NullRHI` only if there is no usable GPU, texture baking will then fail),
`-abslog=<file>` for a predictable log location.

### Verified command line

Tested on 2026-11-06 with UE 5.8.4 (installed Linux build), project `UnrealSurvival`
(Blueprint-only) and the Fab pack `/Game/Laundromat/VOL2_Laundry`:

```sh
"/run/media/alex/S Backup L/Linux_Unreal_Engine_5.8.4/Engine/Binaries/Linux/UnrealEditor-Cmd" \
  "/run/media/alex/S Backup L/GitHub/UnrealSurvival/UnrealSurvival.uproject" \
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
