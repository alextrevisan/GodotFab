#!/usr/bin/env bash
# Installs the GodotFab commandlet into the UnrealToGodot plugin of a project and
# rebuilds the plugin with the installed engine's UnrealBuildTool.
#
#   unreal/install_commandlet.sh <engine_dir> <uproject>
#
# <engine_dir> is the root of an installed Unreal Engine (contains Engine/Build/BatchFiles/Linux/Build.sh).
# <uproject>   is the .uproject whose Plugins/UnrealToGodot/ should receive the commandlet.
#
# Plugins/UnrealToGodot/Binaries is backed up to Binaries.bak-<timestamp> (only the most
# recent backup is kept) and restored if the build fails.
set -uo pipefail

if [ $# -ne 2 ]; then
	echo "usage: $0 <engine_dir> <uproject>" >&2
	exit 2
fi

ENGINE="$1"
UPROJECT="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/UnrealToGodotCommandlet"
PROJECT_DIR="$(cd "$(dirname "$UPROJECT")" && pwd)"
UPROJECT="$PROJECT_DIR/$(basename "$UPROJECT")"
PLUGIN_DIR="$PROJECT_DIR/Plugins/UnrealToGodot"
DEST_DIR="$PLUGIN_DIR/Source/UnrealToGodot/Public"
BUILD_SH="$ENGINE/Engine/Build/BatchFiles/Linux/Build.sh"
SO="$PLUGIN_DIR/Binaries/Linux/libUnrealEditor-UnrealToGodot.so"

for f in "$BUILD_SH" "$UPROJECT" "$SRC_DIR/UnrealToGodotCommandlet.h" "$SRC_DIR/UnrealToGodotCommandlet.cpp"; do
	if [ ! -f "$f" ]; then
		echo "error: missing $f" >&2
		exit 2
	fi
done
if [ ! -d "$DEST_DIR" ]; then
	echo "error: plugin source directory not found: $DEST_DIR" >&2
	exit 2
fi

echo "== Copying commandlet sources to $DEST_DIR"
cp -f "$SRC_DIR/UnrealToGodotCommandlet.h" "$SRC_DIR/UnrealToGodotCommandlet.cpp" "$DEST_DIR/" || exit 1

# The exporter pops the GLTF export-options window for the first mesh
# (SGLTFExportOptionsWindow::ShowDialog). Commandlets have no Slate application, so
# that call asserts. Guard it with FApp::IsUnattended() (one line, idempotent).
GODOT_SCENE="$DEST_DIR/GodotScene.cpp"
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'if (ShowOptions && !FApp::IsUnattended())' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for unattended mode"
	elif grep -qF "$(printf '\t\tif (ShowOptions)')" "$GODOT_SCENE"; then
		cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		# the plugin sources use CRLF line endings: keep the \r
		sed -i '/^\t\tif (ShowOptions)\r*$/s/if (ShowOptions)/if (ShowOptions \&\& !FApp::IsUnattended())/' "$GODOT_SCENE" || exit 1
		if ! grep -q 'if (ShowOptions && !FApp::IsUnattended())' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: GLTF options dialog skipped when unattended (original kept as GodotScene.cpp.godotfab-orig)"
	else
		echo "warning: could not find 'if (ShowOptions)' in $GODOT_SCENE; the GLTF options dialog may block or assert in unattended runs" >&2
	fi
	# Patch 2: the prefab's mesh CollisionShape3D must not carry the source instance's world transform
	# (collisions end up offset twice in the scene). Only child primitives (Box0, Capsule0…) keep theirs.
	if grep -q 'Shape->Owner == Prefab' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for prefab collisions"
	elif grep -qF 'std::string TransformText = GenerateTransformText( TC );' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		sed -i 's/^\t\t\t\tstd::string TransformText = GenerateTransformText( TC );\(\r*\)$/\t\t\t\tstd::string TransformText = ( Shape->Owner == Prefab ) ? std::string() : GenerateTransformText( TC );\1/' "$GODOT_SCENE" || exit 1
		if ! grep -q 'Shape->Owner == Prefab' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (prefab collisions) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: prefab mesh collision keeps identity transform"
	else
		echo "warning: could not find the prefab collision transform line in $GODOT_SCENE; prefab collisions may be offset (the Godot importer also fixes them)" >&2
	fi
	# Patch 3: GenerateParentName walks from the node up to the root and appends each name, so a
	# node two levels deep gets a reversed parent path ("StaticMesh/Actor" instead of
	# "Actor/StaticMesh") and Godot drops it ("Parent path ... has vanished"). Prefab instances used
	# only the direct parent's name. Prepend instead, and use the full path for instances.
	if grep -q 'GodotFab: parent path order' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for parent paths"
	elif grep -qF 'Ret += Parent->Name;' "$GODOT_SCENE" && grep -qF 'ParentName = GO->Parent->Name;' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		perl -0pi -e 's/if\( NumParents > 0 \)\r?\n(\t+)\{\r?\n\t+Ret \+= "\/";\r?\n\t+\}\r?\n(\t+)Ret \+= Parent->Name;/Ret = Parent->Name + ( NumParents > 0 ? "\/" + Ret : std::string() );\/\/ GodotFab: parent path order/' "$GODOT_SCENE" || exit 1
		sed -i 's/^\t\tParentName = GO->Parent->Name;\(\r*\)$/\t\tParentName = GenerateParentName( GO );\1/' "$GODOT_SCENE" || exit 1
		if ! grep -q 'GodotFab: parent path order' "$GODOT_SCENE" || ! grep -qF 'ParentName = GenerateParentName( GO );' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (parent paths) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: nested parent paths written root first"
	else
		echo "warning: could not find GenerateParentName's loop in $GODOT_SCENE; nested nodes may get reversed parent paths (the Godot importer also fixes them)" >&2
	fi
fi

# Patch 4: FixSkeletalMeshBoneInfluences uses USkeletalMesh::GetLODInfoArray(), deprecated since
# UE 5.5. Its shim fills a thread_local array with SetNumUninitialized(N) and then Add()s N more,
# so the array holds garbage and the next call destroys it: SIGSEGV in DestructItems as soon as a
# level has more than one skeletal mesh (Medieval Village). It also edited copies, so the bone
# influence limit was never applied. Use GetLODNum()/GetLODInfo(), which point at the source models.
UTX_MODULE="$DEST_DIR/UTXModule.cpp"
if [ -f "$UTX_MODULE" ]; then
	if grep -q 'GodotFab: LOD info' "$UTX_MODULE"; then
		echo "== UTXModule.cpp already patched for skeletal LOD info"
	elif grep -qF 'TArray<FSkeletalMeshLODInfo>& LODInfoArray = SkeletalMesh->GetLODInfoArray();' "$UTX_MODULE"; then
		[ -f "$UTX_MODULE.godotfab-orig" ] || cp -f "$UTX_MODULE" "$UTX_MODULE.godotfab-orig"
		perl -0pi -e 's/TArray<FSkeletalMeshLODInfo>& LODInfoArray = SkeletalMesh->GetLODInfoArray\(\);\r?\n(\t+)for\( int i = 0; i < LODInfoArray\.Num\(\); i\+\+ \)\r?\n(\t+)\{\r?\n(\t+)FSkeletalMeshLODInfo& LODInfo = LODInfoArray\[ i \];/for( int i = 0; i < SkeletalMesh->GetLODNum(); i++ )\/\/ GodotFab: LOD info\n$1\{\n$3if( !SkeletalMesh->GetLODInfo( i ) ) continue;\n$3FSkeletalMeshLODInfo& LODInfo = *SkeletalMesh->GetLODInfo( i );/' "$UTX_MODULE" || exit 1
		if ! grep -q 'GodotFab: LOD info' "$UTX_MODULE" || grep -qF 'SkeletalMesh->GetLODInfoArray();' "$UTX_MODULE"; then
			echo "error: patching $UTX_MODULE (skeletal LOD info) failed" >&2
			exit 1
		fi
		echo "== Patched UTXModule.cpp: skeletal LOD info read through GetLODInfo (original kept as UTXModule.cpp.godotfab-orig)"
	else
		echo "warning: could not find GetLODInfoArray in $UTX_MODULE; levels with several skeletal meshes may crash the export" >&2
	fi
fi

# Patch 5: ConvertRVTTextures dereferences the RVT volume's streaming texture without checking it.
# A Runtime Virtual Texture volume whose streaming texture was never built (Medieval Village
# landscape) has StreamingTexture->Texture == nullptr: SIGSEGV. Skip those volumes; the
# materials then keep their regular inputs.
BASE_SCENE="$DEST_DIR/BaseScene.cpp"
if [ -f "$BASE_SCENE" ]; then
	if grep -q 'GodotFab: unbuilt RVT' "$BASE_SCENE"; then
		echo "== BaseScene.cpp already patched for unbuilt RVT textures"
	elif grep -qF 'if( RVT && StreamingTexture && !ConvertedTextures.Find( RVT ) )' "$BASE_SCENE"; then
		[ -f "$BASE_SCENE.godotfab-orig" ] || cp -f "$BASE_SCENE" "$BASE_SCENE.godotfab-orig"
		sed -i 's/if( RVT \&\& StreamingTexture \&\& !ConvertedTextures.Find( RVT ) )/if( RVT \&\& StreamingTexture \&\& StreamingTexture->Texture \&\& !ConvertedTextures.Find( RVT ) )\/\/ GodotFab: unbuilt RVT/' "$BASE_SCENE" || exit 1
		if ! grep -q 'GodotFab: unbuilt RVT' "$BASE_SCENE"; then
			echo "error: patching $BASE_SCENE (unbuilt RVT) failed" >&2
			exit 1
		fi
		echo "== Patched BaseScene.cpp: RVT volumes without a built streaming texture skipped (original kept as BaseScene.cpp.godotfab-orig)"
	else
		echo "warning: could not find the RVT streaming texture check in $BASE_SCENE; levels with unbuilt RVT volumes may crash the export" >&2
	fi
fi

BACKUP=""
if [ -d "$PLUGIN_DIR/Binaries" ]; then
	# keep a single backup
	for old in "$PLUGIN_DIR"/Binaries.bak-*; do
		[ -e "$old" ] && rm -rf "$old"
	done
	BACKUP="$PLUGIN_DIR/Binaries.bak-$(date +%Y%m%d-%H%M%S)"
	echo "== Backing up $PLUGIN_DIR/Binaries to $BACKUP"
	cp -a "$PLUGIN_DIR/Binaries" "$BACKUP" || exit 1
fi

restore_backup() {
	if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
		echo "== Restoring $BACKUP to $PLUGIN_DIR/Binaries"
		rm -rf "$PLUGIN_DIR/Binaries"
		cp -a "$BACKUP" "$PLUGIN_DIR/Binaries"
	fi
}

echo "== Building UnrealEditor Linux Development for $UPROJECT"
START=$(date +%s)
"$BUILD_SH" UnrealEditor Linux Development -Project="$UPROJECT" -TargetType=Editor -Progress -NoHotReloadFromIDE
STATUS=$?
echo "== Build finished with status $STATUS after $(( $(date +%s) - START )) s"

if [ $STATUS -ne 0 ]; then
	restore_backup
	echo "error: build failed (status $STATUS); previous binaries restored" >&2
	exit $STATUS
fi

if [ ! -f "$SO" ]; then
	restore_backup
	echo "error: $SO not found after build; previous binaries restored" >&2
	exit 1
fi

COUNT=$(grep -c UnrealToGodotCommandlet "$SO" || true)
echo "== grep -c UnrealToGodotCommandlet on the plugin .so: $COUNT"
if [ "${COUNT:-0}" -lt 1 ]; then
	restore_backup
	echo "error: commandlet symbol not found in $SO; previous binaries restored" >&2
	exit 1
fi

echo "== Commandlet installed. Run it with:"
echo "   \"$ENGINE/Engine/Binaries/Linux/UnrealEditor-Cmd\" \"$UPROJECT\" -run=UnrealToGodot.UnrealToGodot -ContentPath=/Game/<Pack> [-Map=/Game/<Pack>/Maps/<Map>] -Output=<dir> -unattended -nopause -nosplash -AllowCommandletRendering -log -abslog=<logfile>"
