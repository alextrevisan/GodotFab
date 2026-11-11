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

if [ -f "$GODOT_SCENE" ]; then
	# Patch 6: a mesh collider whose mesh has no convex hulls nor the collision LOD writes no
	# ConcavePolygonShape3D, but the CollisionShape3D node still references its id. Godot refuses
	# the prefab ("Invalid parameter") and the editor can't open any scene instancing it
	# (Medieval Village walls). Clear the id when nothing was written and skip that node.
	if grep -q 'GodotFab: missing shape' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for missing collision shapes"
	elif grep -qF 'else if( Shape->Type == CT_MESHCOLLIDER )' "$GODOT_SCENE" && grep -qF 'if ( VertexArray.length() > 0 )' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		perl -0pi -e 's/(else if\( Shape->Type == CT_MESHCOLLIDER \)\r?\n(\t+)\{\r?\n)/$1$2\tShapesSubresourceIDs.back().clear();\/\/ GodotFab: missing shape\r\n/; s/(if \( VertexArray\.length\(\) > 0 \)\r?\n(\t+)\{\r?\n)/$1$2\tShapesSubresourceIDs.back() = LocalGUID;\r\n/; s/(ExportComponent\* Shape = PhysicsShapes\[ s \];\r?\n(\t+))(std::string ShapeNode)/$1if( ShapesSubresourceIDs[ s ].empty() ) continue;\r\n$2$3/' "$GODOT_SCENE" || exit 1
		if [ "$(grep -c 'ShapesSubresourceIDs.back() = LocalGUID;\|ShapesSubresourceIDs\[ s \].empty()\|GodotFab: missing shape' "$GODOT_SCENE")" -ne 3 ]; then
			echo "error: patching $GODOT_SCENE (missing collision shapes) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: collision nodes without a written shape skipped"
	else
		echo "warning: could not find the mesh collider shape code in $GODOT_SCENE; prefabs of meshes without collision may not load (the Godot importer also fixes them)" >&2
	fi
	# Patch 7: FixCustomExpressionCode turns "#if X" into "#if 0//X" and then normalizeNumbers adds
	# ".0" to every number: "#if 0.0//COMPILER_HLSL". Godot's preprocessor only takes integer
	# conditions and rejects the whole shader ("Unknown character '#'" at the first directive).
	if grep -q 'GodotFab: integer #if' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for float #if conditions"
	elif grep -qF 'Expression = normalizeNumbers( Expression );' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		perl -0pi -e 's/(\t+)(Expression = normalizeNumbers\( Expression \);)(\r?\n)/$1$2$3$1StringReplacement( Expression, "#if 0.0\/\/", "#if 0\/\/" );\/\/ GodotFab: integer #if$3/' "$GODOT_SCENE" || exit 1
		if ! grep -q 'GodotFab: integer #if' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (float #if) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: custom expression #if conditions stay integers"
	else
		echo "warning: could not find normalizeNumbers in $GODOT_SCENE; custom expressions with #if may not compile (the Godot importer also fixes them)" >&2
	fi
	# Patch 8: static bool parameters reach GenerateBoolParameterNode with the raw Unreal name
	# ("Level 1 Wind"), while the material gets the sanitized one. Godot writes the name into the
	# uniform declaration and the shader fails ("Expected a ';'"). Pass the sanitized name, and
	# sanitize inside the function for the material function preview path too.
	if grep -q 'GodotFab: sanitized bool names' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for bool parameter names"
	elif grep -qF 'const char* GenerateBoolParameterNode( bool DefaultValue, FString ParameterName, std::string& Params )' "$GODOT_SCENE" && grep -qF 'return GenerateBoolParameterNode( BoolValue, ParamName, Params );' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		perl -0pi -e 's/(const char\* GenerateBoolParameterNode\( bool DefaultValue, FString ParameterName, std::string& Params \)\r?\n\{\r?\n)/$1\tSanitizeParamName( ParameterName );\/\/ GodotFab: sanitized bool names\r\n/; s/return GenerateBoolParameterNode\( BoolValue, ParamName, Params \);/return GenerateBoolParameterNode( BoolValue, SanitizedParamName, Params );/' "$GODOT_SCENE" || exit 1
		if ! grep -q 'GodotFab: sanitized bool names' "$GODOT_SCENE" || ! grep -qF 'GenerateBoolParameterNode( BoolValue, SanitizedParamName, Params )' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (bool parameter names) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: bool parameter names sanitized"
	else
		echo "warning: could not find GenerateBoolParameterNode in $GODOT_SCENE; parameter names with spaces may break shaders (the Godot importer also fixes them)" >&2
	fi
fi

# Patch 9: ProcessMeshComponent exports what ShouldRender() shows in the editor, which includes
# actors marked "Actor Hidden In Game" (Medieval Village: 179 blockout cubes around the
# village) and meshes whose material has the Volume domain (local volumetric fog boxes that
# Unreal renders as fog, not as a surface). Skip both: Godot is the game, not the editor.
EXPORT_TO_UNITY="$DEST_DIR/ExportToUnity.cpp"
if [ -f "$EXPORT_TO_UNITY" ]; then
	if grep -q 'GodotFab: hidden in game' "$EXPORT_TO_UNITY"; then
		echo "== ExportToUnity.cpp already patched for hidden-in-game meshes"
	elif grep -qF 'if( (StaticMeshComp && !StaticMesh ) || (SkeletalMeshComponent && !SkeletalMesh) || !IsVisible )' "$EXPORT_TO_UNITY"; then
		[ -f "$EXPORT_TO_UNITY.godotfab-orig" ] || cp -f "$EXPORT_TO_UNITY" "$EXPORT_TO_UNITY.godotfab-orig"
		perl -0pi -e 's/(\r?\n)(\t+)(if\( \(StaticMeshComp && !StaticMesh \) \|\| \(SkeletalMeshComponent && !SkeletalMesh\) \|\| !IsVisible \))/$1$2if( Actor && Actor->IsHidden() ) IsVisible = false;\/\/ GodotFab: hidden in game$1$2if( StaticMeshComp && StaticMeshComp->bHiddenInGame ) IsVisible = false;$1$2if( StaticMeshComp && StaticMeshComp->GetMaterial( 0 ) && StaticMeshComp->GetMaterial( 0 )->GetMaterial() && StaticMeshComp->GetMaterial( 0 )->GetMaterial()->MaterialDomain == MD_Volume ) IsVisible = false;$1$2$3/' "$EXPORT_TO_UNITY" || exit 1
		if ! grep -q 'GodotFab: hidden in game' "$EXPORT_TO_UNITY"; then
			echo "error: patching $EXPORT_TO_UNITY (hidden in game) failed" >&2
			exit 1
		fi
		echo "== Patched ExportToUnity.cpp: hidden-in-game and volume-domain meshes skipped (original kept as ExportToUnity.cpp.godotfab-orig)"
	else
		echo "warning: could not find the mesh visibility check in $EXPORT_TO_UNITY; actors hidden in game will be exported" >&2
	fi
fi

# Patch 10: lights. Godot's physical light units match Unreal's: lux for the sun, lumens for
# point/spot/rect lights. The exporter wrote the sun x10000 and the others x1000 with
# light_energy 16 (a 12000 lux sun became 120 million lux). Write them 1:1; the commandlet
# writes the level's exposure into CameraAttributes.tres.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: physical light units' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for light units"
	elif grep -qF 'NewLightComponent->Intensity = DirectionalLightComp->Intensity * 10000;' "$GODOT_SCENE" && grep -qF 'Energy = 16.0f;' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		sed -i 's/NewLightComponent->Intensity = DirectionalLightComp->Intensity \* 10000;/NewLightComponent->Intensity = DirectionalLightComp->Intensity;\/\/ GodotFab: physical light units/; s/NewLightComponent->Intensity = \(PointLightComp\|SpotLightComp\|RectLightComponent\)->Intensity \* 1000;/NewLightComponent->Intensity = \1->Intensity;/; s/^\(\t\t\t\t\)Energy = 16.0f;/\1Energy = 1.0f;/' "$GODOT_SCENE" || exit 1
		if ! grep -q 'GodotFab: physical light units' "$GODOT_SCENE" || grep -q 'Intensity \* 1000;' "$GODOT_SCENE" || grep -qF 'Energy = 16.0f;' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (light units) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: lights written in physical units 1:1"
	else
		echo "warning: could not find the light intensity conversion in $GODOT_SCENE; lights may be far too bright" >&2
	fi
fi

# Patch 11: Unreal Custom expression inputs take the type of whatever is connected, and HLSL
# truncates implicitly on "return InValue;" (a float4 input into a float3 output, Medieval
# Village's MakePreciseV3). The exporter turns "return" into "output0 =", which Godot refuses
# ("Invalid arguments to operator '=': 'vec3, vec4'"); Godot's shading language has no
# vec3(vec4) constructor either. Rewrite exactly "output0 = <Input>;" with a swizzle
# (".xyz", ".xy" or ".x") when <Input> is a wider vector than the declared output.
# An earlier version of this patch cast with vec3(...): remove it first.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: cast custom output' "$GODOT_SCENE"; then
		perl -0pi -e 's/\/\/ GodotFab: cast custom output\r?\nstatic void GodotFabCastCustomOutput\( std::string& E, GodotShaderVariableType Type \)\r?\n\{.*?\r?\n\}\r?\n//s; s/\t+GodotFabCastCustomOutput\( ExpressionStr, OutputType \);\r?\n//' "$GODOT_SCENE" || exit 1
		if grep -q 'GodotFab: cast custom output\|GodotFabCastCustomOutput( ExpressionStr, OutputType )' "$GODOT_SCENE"; then
			echo "error: removing the previous custom output cast from $GODOT_SCENE failed" >&2
			exit 1
		fi
		echo "== Removed the previous custom output cast (vec3(...)) from GodotScene.cpp"
	fi
	if grep -q 'GodotFab: swizzle custom output' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for custom expression output swizzles"
	elif grep -qF 'void FixCustomExpressionCode( std::string& Expression, UShaderType ShaderType )' "$GODOT_SCENE" && [ "$(grep -cF 'return GenerateShaderExpression( Parameters, ExpressionStr.c_str(), Params, Subresource);' "$GODOT_SCENE")" -eq 1 ]; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		perl -0pi -e 's/(void FixCustomExpressionCode\( std::string& Expression, UShaderType ShaderType \)\r?\n)/\/\/ GodotFab: swizzle custom output\r\nstatic void GodotFabSwizzleCustomOutput( std::string& E, GodotShaderVariableType Out, const std::vector< GodotShaderExpressionParameter* >& Parameters )\r\n{\r\n\tif( Out != GSVT_FLOAT && Out != GSVT_VECTOR2 && Out != GSVT_VECTOR3 )\r\n\t\treturn;\r\n\tconst std::string Swizzle = Out == GSVT_FLOAT ? "x" : ( Out == GSVT_VECTOR2 ? "xy" : "xyz" );\r\n\tfor( GodotShaderExpressionParameter* P : Parameters )\r\n\t{\r\n\t\tif( !P || !P->IsInput || P->Type < GSVT_VECTOR2 || P->Type > GSVT_VECTOR4 || P->Type <= Out )\r\n\t\t\tcontinue;\r\n\t\tconst std::string From = "output0 = " + P->Name + ";";\r\n\t\tconst std::string To = "output0 = " + P->Name + "." + Swizzle + ";";\r\n\t\tfor( size_t p = E.find( From ); p != std::string::npos; p = E.find( From, p + To.size() ) )\r\n\t\t\tE.replace( p, From.size(), To );\r\n\t}\r\n}\r\n$1/; s/(\t+)(return GenerateShaderExpression\( Parameters, ExpressionStr\.c_str\(\), Params, Subresource\);)/$1GodotFabSwizzleCustomOutput( ExpressionStr, OutputType, Parameters );\r\n$1$2/' "$GODOT_SCENE" || exit 1
		if [ "$(grep -c 'GodotFabSwizzleCustomOutput' "$GODOT_SCENE")" -ne 2 ]; then
			echo "error: patching $GODOT_SCENE (custom output swizzles) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: custom expression passthrough outputs swizzled to the declared type"
	else
		echo "warning: could not find the Custom expression code in $GODOT_SCENE; custom outputs with a wider input may not compile" >&2
	fi
fi

# Patch 12: resource UIDs are std::hash of the file's absolute path, output folder included,
# so exporting to another folder (or moving the project) changes every UID. Every reference
# then changes too, and a reimport rewrites every .import, which makes Godot recompress every
# texture. Hash the path relative to the output folder instead.
if [ -f "$BASE_SCENE" ] && [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: stable GUIDs' "$BASE_SCENE"; then
		echo "== BaseScene.cpp/GodotScene.cpp already patched for stable GUIDs"
	elif grep -qF 'void ExportTexture::GenerateGUID()' "$BASE_SCENE" && grep -qF 'std::string GetGodotGUID( std::string Input )' "$GODOT_SCENE"; then
		[ -f "$BASE_SCENE.godotfab-orig" ] || cp -f "$BASE_SCENE" "$BASE_SCENE.godotfab-orig"
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		perl -0pi -e 's/(void ExportTexture::GenerateGUID\(\)\r?\n)/\/\/ GodotFab: stable GUIDs (hash paths relative to the output folder)\r\nstd::string GodotFabStableKey( const std::string& Path )\r\n{\r\n\tif( !ExporterInterface )\r\n\t\treturn Path;\r\n\tconst std::string Root = ToANSIString( *ExporterInterface->GetAssetsFolder() );\r\n\tif( !Root.empty() && Path.compare( 0, Root.size(), Root ) == 0 )\r\n\t\treturn Path.substr( Root.size() );\r\n\treturn Path;\r\n}\r\n$1/; s/std::hash<std::string>\{\}\( (\S+) \)/std::hash<std::string>{}( GodotFabStableKey( $1 ) )/g' "$BASE_SCENE" || exit 1
		perl -0pi -e 's/(#include "GodotScene\.h"\r?\n)/$1std::string GodotFabStableKey( const std::string& Path );\/\/ GodotFab: stable GUIDs (BaseScene.cpp)\r\n/; s/std::hash<std::string>\{\}\( (\S+) \)/std::hash<std::string>{}( GodotFabStableKey( $1 ) )/g' "$GODOT_SCENE" || exit 1
		if ! grep -q 'GodotFab: stable GUIDs' "$BASE_SCENE" || ! grep -q 'GodotFab: stable GUIDs' "$GODOT_SCENE" || grep -qE 'std::hash<std::string>\{\}\( (File|Input|FileName|str|Material->File) \)' "$BASE_SCENE" "$GODOT_SCENE"; then
			echo "error: patching stable GUIDs failed" >&2
			exit 1
		fi
		echo "== Patched BaseScene.cpp/GodotScene.cpp: resource GUIDs hashed from paths relative to the output folder"
	else
		echo "warning: could not find the GUID hash code; resource UIDs will change with the output folder" >&2
	fi
fi

# Patch 13: Nanite meshes. OnExportBegin turns on the GLTF option bExportSourceModel (needed
# for Metahumans) and saves it to the user's config, so the GLTF exporter writes the source
# model of every static mesh. For a Nanite mesh that is the full-resolution original (Medieval
# Village's SM_IcelandicTerrain_High: 2 million triangles instead of the 12 thousand of its
# fallback mesh, 165 instances), ignoring NANITE_COARSE_MESH. Godot then voxelizes hundreds of
# millions of triangles for SDFGI and the GPU driver resets. Export the render data (the
# Nanite fallback mesh) for Nanite static meshes unless -NaniteOriginal was given.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: Nanite fallback mesh' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for Nanite fallback meshes"
	elif [ "$(grep -cF 'bool Status = UseUEExporter( Exporter, Asset, MeshFile, false, Options );' "$GODOT_SCENE")" -eq 1 ]; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		perl -0pi -e 's/(\t+)(bool Status = UseUEExporter\( Exporter, Asset, MeshFile, false, Options \);)/$1\/\/ GodotFab: Nanite fallback mesh\r\n$1if( MB->UnrealStaticMesh && MB->UnrealStaticMesh->NaniteSettings.bEnabled && Settings->NaniteOptions != NaniteOptionsEnum::NANITE_ORIGINAL_MESH )\r\n$1\tOptions->bExportSourceModel = false;\r\n$1$2/' "$GODOT_SCENE" || exit 1
		if ! grep -q 'GodotFab: Nanite fallback mesh' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (Nanite fallback meshes) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: Nanite static meshes exported from their fallback mesh"
	else
		echo "warning: could not find the GLTF mesh export call in $GODOT_SCENE; Nanite meshes will be exported at full resolution" >&2
	fi
fi

# Patch 14: AppendVector. Output 0 of an Unreal vector parameter is RGB (float3), but it is
# wired to output 0 of Godot's Vec4Parameter, which is a vec4. Appending its alpha (Medieval
# Village's landscape material: Append(DirtUVParams_VS, DirtUVParams_VS.A)) then generated
# "vec4(input0, input1)" with a vec4 and a float, which Godot refuses ("Invalid arguments for
# the built-in function vec4(vec4,float)"). Unreal never appends past 4 components, so when
# the inputs add up to more than 4, swizzle input A down to what is left.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: append overflow' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for AppendVector overflow"
	elif grep -qF '"output0 = %s(input0, input1);\n",' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		python3 - "$GODOT_SCENE" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, newline="").read()
pat = re.compile(r'(\t+)(const char\* OutTypeStr = GetShaderVariableTypeName\( OutType \);\r?\n'
                 r'[\t ]+snprintf\( Text, sizeof\( Text \),\r?\n'
                 r'[\t ]+"//AppendVector:%d\(%s\)\\n"\r?\n[\t ]+)"output0 = %s\(input0, input1\);\\n",'
                 r'(\r?\n[\t ]+Subresource->ID,\r?\n[\t ]+Subresource->GetFunctionCallName\(\)\.c_str\(\),\r?\n[\t ]+OutTypeStr)')
def repl(m):
    t = m.group(1)
    nl = "\r\n"
    return (t + "// GodotFab: append overflow" + nl +
            t + 'std::string GodotFabA = "input0";' + nl +
            t + "{" + nl +
            t + "\tconst int CA = GetNumComponentsFromVectorType( InType0 ), CB = GetNumComponentsFromVectorType( InType1 );" + nl +
            t + "\tif( CA + CB > 4 && CB < 4 )" + nl +
            t + '\t\tGodotFabA += ( 4 - CB == 1 ) ? ".x" : ( ( 4 - CB == 2 ) ? ".xy" : ".xyz" );' + nl +
            t + "}" + nl +
            t + m.group(2) + '"output0 = %s(%s, input1);\\n",' + m.group(3) + "," + nl +
            t + "\t\t  GodotFabA.c_str()")
src, n = pat.subn(repl, src)
if n != 1:
    sys.exit("AppendVector pattern matched %d times" % n)
open(path, "w", newline="").write(src)
PY
		if ! grep -q 'GodotFab: append overflow' "$GODOT_SCENE" || ! grep -qF 'GodotFabA.c_str()' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (AppendVector overflow) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: AppendVector inputs swizzled when they add up to more than 4 components"
	else
		echo "warning: could not find the AppendVector code in $GODOT_SCENE; appending a vector parameter's alpha may not compile" >&2
	fi
fi

# Patch 15: unique node names. Nodes are named after Unreal actor labels, which do not have
# to be unique (Medieval Village: 1116 root nodes repeat a sibling's name, e.g. two
# PlayerStart). Godot renames them on load and the editor tries to pop up a dialog for each
# one ("Attempting to parent and popup a dialog that already has a parent", 1525 times).
# Before writing the level, append _2, _3... to names already used under the same parent.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: unique node names' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for unique node names"
	elif [ "$(grep -cF '"[node name=\"Root\" type=\"Node3D\"]\n"' "$GODOT_SCENE")" -eq 1 ]; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		python3 - "$GODOT_SCENE" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, newline="").read()
pat = re.compile(r'(\t+"\[node name=\\"Root\\" type=\\"Node3D\\"\]\\n"\r?\n[\t ]+"\\n";\r?\n)')
nl = "\r\n"
block = (nl +
    "\t// GodotFab: unique node names" + nl +
    "\t{" + nl +
    "\t\tTMap< GameObject*, TSet< FString > > UsedNames;" + nl +
    "\t\tfor( GameObject* G : Scene->GameObjects )" + nl +
    "\t\t{" + nl +
    "\t\t\tif( !G )" + nl +
    "\t\t\t\tcontinue;" + nl +
    "\t\t\tTSet< FString >& Names = UsedNames.FindOrAdd( G->Parent );" + nl +
    "\t\t\tif( !G->Parent && Names.Num() == 0 )" + nl +
    "\t\t\t\tNames.Add( TEXT( \"WorldEnvironment\" ) );" + nl +
    "\t\t\tconst FString Base = UTF8_TO_TCHAR( G->Name.c_str() );" + nl +
    "\t\t\tFString Name = Base;" + nl +
    "\t\t\tfor( int32 N = 2; Names.Contains( Name ); N++ )" + nl +
    "\t\t\t\tName = FString::Printf( TEXT( \"%s_%d\" ), *Base, N );" + nl +
    "\t\t\tif( Name != Base )" + nl +
    "\t\t\t\tG->Name = TCHAR_TO_UTF8( *Name );" + nl +
    "\t\t\tNames.Add( Name );" + nl +
    "\t\t}" + nl +
    "\t}" + nl)
src, n = pat.subn(lambda m: m.group(1) + block, src)
if n != 1:
    sys.exit("Root node pattern matched %d times" % n)
open(path, "w", newline="").write(src)
PY
		if ! grep -q 'GodotFab: unique node names' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (unique node names) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: sibling node names made unique"
	else
		echo "warning: could not find the level root node in $GODOT_SCENE; repeated actor names will be renamed by Godot" >&2
	fi
fi

# Patch 16: connections to expressions that were never generated. An expression whose output
# is not used gets no shader node (ID -1), but the connections into it are still written
# (Medieval Village: MI_OldStump, MI_TreeStumpB, MI_RoadB, MI_MossyEmbankmentA). Godot logs
# 'Condition "!nodes.has(p_to_node)" is true' for each. Skip connections with a negative ID.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: skip dangling connections' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for dangling shader connections"
	elif [ "$(grep -cF '"%d, %d, %d, %d", Connection.SourceNode, Connection.SourceNodeOutput,' "$GODOT_SCENE")" -eq 1 ]; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		perl -0pi -e 's/^(\t+)(ShaderConnection& Connection = ShaderData\.Connections\[ i \];\r?\n)(\s*\r?\n\t+snprintf\( Text, sizeof\( Text \), "%d, %d, %d, %d", Connection\.SourceNode)/$1$2$1if( Connection.SourceNode < 0 || Connection.DestinationNode < 0 )\/\/ GodotFab: skip dangling connections\r\n$1\tcontinue;\r\n$3/m' "$GODOT_SCENE" || exit 1
		if ! grep -q 'GodotFab: skip dangling connections' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (dangling shader connections) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: shader connections to ungenerated expressions skipped"
	else
		echo "warning: could not find the shader connection writer in $GODOT_SCENE; dangling connections will be written" >&2
	fi
fi

# Patch 17: unlit materials blown out. Unreal Unlit emissive is in nits and gets exposed by the
# camera, but the plugin writes it to ALBEDO of an unshaded shader, which Godot (with physical
# light units) never multiplies by the camera exposure: the Medieval Village candle flames
# (IntensityMult 6000) render ~600x too bright and glow as big white blobs. Write unlit emissive
# to EMISSION as is (Godot also takes EMISSION in nits and applies the exposure), with a black
# albedo, zero specular, specular_disabled and ambient_light_disabled so only the emission shows.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: unlit emissive' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for unlit emissive"
	elif grep -q 'EmissiveOutput = AlbedoOutput;' "$GODOT_SCENE" && grep -q 'ExtraFlags += "flags/unshaded = true\\n";' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		python3 - "$GODOT_SCENE" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, newline="").read()
nl = "\r\n" if "\r\n" in src else "\n"
unlit = "Mat->MaterialInterface->GetShadingModels().HasOnlyShadingModel( EMaterialShadingModel::MSM_Unlit )"

def sub(pattern, repl, what):
    global src
    src, n = re.subn(pattern, repl, src, flags=re.M)
    if n != 1:
        sys.exit("%s pattern matched %d times" % (what, n))

# Keep unlit emissive on the EMISSION port; unlit has no base color.
sub(r"^([\t ]+)EmissiveOutput = AlbedoOutput;\r?\n([\t ]+)AlbedoOutput = -1;",
    lambda m: m.group(2) + "AlbedoOutput = -1;// GodotFab: unlit emissive", "unlit outputs")
# Only clamp the albedo when something is connected to it.
sub(r"^([\t ]+)if\( BaseColorInput->Expression \)(\r?\n[\t ]+\{\r?\n[\t ]+FixAlbedoOutput\( ShaderData \);)",
    lambda m: m.group(1) + "if( BaseColorInput->Expression && ShaderData.GetShaderConnection( 0, 0, UST_FRAGMENT ) )" + m.group(2), "albedo fix")
# Unlit emissive is already in nits: no lit emission multiplier.
sub(r"^([\t ]+)if \( EmissiveInput->Expression \)(\r?\n[\t ]+\{\r?\n[\t ]+FixEmissiveOutput\( ShaderData \);)",
    lambda m: m.group(1) + "if ( EmissiveInput->Expression && !" + unlit + " )" + m.group(2), "emissive fix")
# Black albedo and zero specular for unlit, so lighting adds nothing to the emission.
def outputs(m):
    t = m.group(1)
    lines = [
        "if( " + unlit + " )// GodotFab: unlit emissive outputs",
        "{",
        "\tconst char* Types[ 2 ] = { \"VisualShaderNodeVec3Constant\", \"VisualShaderNodeFloatConstant\" };",
        "\tconst char* Values[ 2 ] = { \"constant = Vector3(0, 0, 0)\\n\", \"constant = 0.0\\n\" };",
        "\tconst int Ports[ 2 ] = { 0, 4 };",
        "\tfor( int k = 0; k < 2; k++ )",
        "\t{",
        "\t\tif( ShaderData.GetShaderConnection( 0, Ports[ k ], UST_FRAGMENT ) )",
        "\t\t\tcontinue;",
        "\t\tGodotShaderNode* ConstNode = GenerateShaderNode( nullptr, nullptr, ShaderData, UST_FRAGMENT, -1, Types[ k ], -400, 0 );",
        "\t\tConstNode->DefinitionText += Values[ k ];",
        "\t\tShaderConnection ToOutput;",
        "\t\tToOutput.SourceNode = ConstNode->ID;",
        "\t\tToOutput.SourceNodeOutput = 0;",
        "\t\tToOutput.DestinationNode = 0;",
        "\t\tToOutput.DestinationNodeInput = Ports[ k ];",
        "\t\tToOutput.ShaderType = UST_FRAGMENT;",
        "\t\tShaderData.AddShaderConnection( ToOutput );",
        "\t}",
        "}",
    ]
    return "".join(t + l + nl for l in lines) + nl + m.group(0)
sub(r"^([\t ]+)AddGlobalExpression\( ShaderData \);", outputs, "AddGlobalExpression")
# Lit pipeline (so EMISSION gets the exposure) without specular or ambient light.
sub(r'ExtraFlags \+= "flags/unshaded = true\\n";',
    lambda m: 'ExtraFlags += "modes/specular = 2\\nflags/ambient_light_disabled = true\\n";// GodotFab: unlit emissive flags', "unshaded flag")
open(path, "w", newline="").write(src)
PY
		if ! grep -q 'GodotFab: unlit emissive outputs' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (unlit emissive) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: unlit emissive written to EMISSION (exposed by the camera)"
	else
		echo "warning: could not find the unlit material code in $GODOT_SCENE; unlit materials will ignore the camera exposure" >&2
	fi
fi

# Patch 18: vector expressions typed as float, and fake local bounds. The type evaluator falls
# back to the widest input, so input-less vector expressions (LocalPosition, local bounds,
# ObjectPositionWS, ...) and BlackBody (a float temperature in, a color out) were typed float:
# a Subtract of LocalPosition became a FloatOp on .x and a QualitySwitch of BlackBody kept only
# .x, so the Medieval Village candle flames lost their vertical gradient and their color (white
# capsules). Those expressions are typed vec3 now. PreSkinnedLocalBounds/ObjectLocalBounds were
# a fixed 0..100 cm box; they now use the bounds of a static mesh that uses the material.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: vector expression types' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for vector expression types and local bounds"
	elif grep -q '"output0 =  vec3( 50.0, 50.0, 50.0 );\\n"//HalfExtents' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		python3 - "$GODOT_SCENE" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, newline="").read()
nl = "\r\n" if "\r\n" in src else "\n"

def sub(pattern, repl, what):
    global src
    src, n = re.subn(pattern, repl, src, flags=re.M)
    if n != 1:
        sys.exit("%s pattern matched %d times" % (what, n))

def block(indent, lines):
    return "".join(indent + l + nl for l in lines)

# 1. Vector types for expressions the input fallback gets wrong.
types = [
    "// GodotFab: vector expression types",
    "if( ExpressionClass )",
    "{",
    "\tstatic const TSet< FString > GodotFabVector3Classes = {",
    "\t\tTEXT( \"MaterialExpressionBlackBody\" ), TEXT( \"MaterialExpressionLocalPosition\" ),",
    "\t\tTEXT( \"MaterialExpressionPreSkinnedLocalBounds\" ), TEXT( \"MaterialExpressionObjectLocalBounds\" ),",
    "\t\tTEXT( \"MaterialExpressionObjectPositionWS\" ), TEXT( \"MaterialExpressionActorPositionWS\" ),",
    "\t\tTEXT( \"MaterialExpressionPreSkinnedPosition\" ), TEXT( \"MaterialExpressionReflectionVectorWS\" ),",
    "\t\tTEXT( \"MaterialExpressionLightVector\" ), TEXT( \"MaterialExpressionParticlePositionWS\" ) };",
    "\tif( GodotFabVector3Classes.Contains( ExpressionClass->GetName() ) )",
    "\t\treturn GSVT_VECTOR3;",
    "}",
]
sub(r"^([\t ]+)int NumComponents = 0;\r?\n([\t ]+)const TArray<FExpressionInput\*> Inputs = GetInputs\( Expression \);",
    lambda m: block(m.group(1), types) + m.group(0), "type fallback")

# 2. Bounds of a static mesh that uses the material (Unreal cm, Unreal axes, like LocalPosition).
helper = [
    "// GodotFab: mesh bounds for local bounds expressions",
    "#include \"Engine/StaticMesh.h\"",
    "static bool GodotFabFindMeshBounds( UMaterialInterface* Material, FBox& OutBox )",
    "{",
    "\tstatic TMap< UMaterialInterface*, FBox > Bounds;",
    "\tstatic int32 IndexedMeshes = -1;",
    "\tif( !Material )",
    "\t\treturn false;",
    "\tfor( int Pass = 0; Pass < 2; Pass++ )",
    "\t{",
    "\t\tif( const FBox* Found = Bounds.Find( Material ) )",
    "\t\t{",
    "\t\t\tOutBox = *Found;",
    "\t\t\treturn true;",
    "\t\t}",
    "\t\tif( UMaterialInterface* Base = Material->GetMaterial() )",
    "\t\t{",
    "\t\t\tif( const FBox* Found = Bounds.Find( Base ) )",
    "\t\t\t{",
    "\t\t\t\tOutBox = *Found;",
    "\t\t\t\treturn true;",
    "\t\t\t}",
    "\t\t}",
    "\t\tint32 NumMeshes = 0;",
    "\t\tfor( TObjectIterator< UStaticMesh > It; It; ++It )",
    "\t\t\tNumMeshes++;",
    "\t\tif( NumMeshes == IndexedMeshes )",
    "\t\t\treturn false;",
    "\t\tIndexedMeshes = NumMeshes;",
    "\t\tBounds.Reset();",
    "\t\tfor( TObjectIterator< UStaticMesh > It; It; ++It )",
    "\t\t{",
    "\t\t\tconst FBox Box = It->GetBoundingBox();",
    "\t\t\tfor( const FStaticMaterial& SM : It->GetStaticMaterials() )",
    "\t\t\t{",
    "\t\t\t\tif( !SM.MaterialInterface )",
    "\t\t\t\t\tcontinue;",
    "\t\t\t\tif( !Bounds.Contains( SM.MaterialInterface ) )",
    "\t\t\t\t\tBounds.Add( SM.MaterialInterface, Box );",
    "\t\t\t\tUMaterialInterface* Base = SM.MaterialInterface->GetMaterial();",
    "\t\t\t\tif( Base && !Bounds.Contains( Base ) )",
    "\t\t\t\t\tBounds.Add( Base, Box );",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\treturn false;",
    "}",
]
sub(r"^std::string GetShaderNodeType\( UMaterialExpression\* Expression, std::string& Params, GodotShaderNode\* Subresource, GodotShaderData& Data, int Dependency = -1 \)",
    lambda m: block("", helper) + m.group(0), "GetShaderNodeType")

def bounds(m):
    t = m.group(1)
    lines = [
        "FBox GodotFabBox( FVector( 0.0 ), FVector( 100.0 ) );",
        "GodotFabFindMeshBounds( Data.Binding ? Data.Binding->MaterialInterface : nullptr, GodotFabBox );",
        "const FVector GodotFabExt = GodotFabBox.GetExtent();",
        "snprintf( Text, sizeof( Text ),",
        "\t\t  \"//%s:%d(%s)\\n\"",
        "\t\t  \"output0 =  vec3( %f, %f, %f );\\n\"//HalfExtents",
        "\t\t  \"output1 =  vec3( %f, %f, %f );\\n\"//Extents",
        "\t\t  \"output2 =  vec3( %f, %f, %f );\\n\"//Min",
        "\t\t  \"output3 =  vec3( %f, %f, %f );\\n\",//Max",
        "\t\t  ToANSIString( *ExpressionClass->GetName() ).c_str(),",
        "\t\t  Subresource->ID,",
        "\t\t  Subresource->GetFunctionCallName().c_str(),",
        "\t\t  GodotFabExt.X, GodotFabExt.Y, GodotFabExt.Z,",
        "\t\t  2.0 * GodotFabExt.X, 2.0 * GodotFabExt.Y, 2.0 * GodotFabExt.Z,",
        "\t\t  GodotFabBox.Min.X, GodotFabBox.Min.Y, GodotFabBox.Min.Z,",
        "\t\t  GodotFabBox.Max.X, GodotFabBox.Max.Y, GodotFabBox.Max.Z",
        ");// GodotFab: real local bounds",
    ]
    return block(t, lines)
sub(r'^([\t ]+)snprintf\( Text, sizeof\( Text \),\r?\n[\t ]+"//%s:%d\(%s\)\\n"\r?\n[\t ]+"output0 =  vec3\( 50\.0, 50\.0, 50\.0 \);\\n"//HalfExtents\r?\n(?:.*\r?\n){6}[\t ]+\);\r?\n',
    bounds, "local bounds")
open(path, "w", newline="").write(src)
PY
		if ! grep -q 'GodotFab: real local bounds' "$GODOT_SCENE" || ! grep -q 'GodotFab: vector expression types' "$GODOT_SCENE"; then
			echo "error: patching $GODOT_SCENE (vector expression types) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: vector expression types and real local bounds"
	else
		echo "warning: could not find the local bounds stub in $GODOT_SCENE; local bounds stay 0..100 cm" >&2
	fi
fi

# Patch 19: float textures. RGBA16F/RGBA32F/R16F sources (Pivot Painter position and vector
# textures, flow maps, HDR data) went through FColor with sRGB conversion and were saved as 8-bit
# PNG: values clamp to 0..1 and lose precision. Spruce Forest's *_PIV texture kept 27 distinct
# pixels out of 1590, every branch pivot ended up at the origin, and the wind/bending stretched
# the trees. Save them as EXR (linear float, exact) instead; GodotFab imports .exr lossless.
if [ -f "$EXPORT_TO_UNITY" ]; then
	if grep -q 'GodotFab: float textures as EXR' "$EXPORT_TO_UNITY"; then
		echo "== ExportToUnity.cpp already patched for float textures"
	elif grep -q 'TextureFileName += TEXT(".hdr" );' "$EXPORT_TO_UNITY"; then
		[ -f "$EXPORT_TO_UNITY.godotfab-orig" ] || cp -f "$EXPORT_TO_UNITY" "$EXPORT_TO_UNITY.godotfab-orig"
		python3 - "$EXPORT_TO_UNITY" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, newline="").read()
nl = "\r\n" if "\r\n" in src else "\n"

def sub(pattern, repl, what):
    global src
    src, n = re.subn(pattern, repl, src, flags=re.M)
    if n != 1:
        sys.exit("%s pattern matched %d times" % (what, n))

helper = [
    "// GodotFab: float textures as EXR",
    "static bool GodotFabIsFloatTexture( UTexture* Tex )",
    "{",
    "\tif( !Tex || !Cast<UTexture2D>( Tex ) || Tex->GetOutermost() == GetTransientPackage() )",
    "\t\treturn false;",
    "\tif( Tex->Source.GetNumBlocks() > 1 || Tex->Source.GetNumSlices() > 1 )",
    "\t\treturn false;",
    "\tconst ETextureSourceFormat Format = Tex->Source.GetFormat();",
    "\treturn Format == TSF_RGBA16F || Format == TSF_RGBA32F || Format == TSF_R16F;",
    "}",
    "static bool GodotFabSaveFloatTexture( UTexture* Tex, const FString& FileName )",
    "{",
    "\tFImage Image;",
    "\tif( !Tex->Source.GetMipImage( Image, 0 ) )",
    "\t\treturn false;",
    "\tFImage Linear;",
    "\tImage.CopyTo( Linear, Tex->Source.GetFormat() == TSF_RGBA32F ? ERawImageFormat::RGBA32F : ERawImageFormat::RGBA16F, EGammaSpace::Linear );",
    "\treturn FImageUtils::SaveImageByExtension( *FileName, Linear );",
    "}",
    "",
]
sub(r"^FString GenerateTexturePath\( UTexture \*Tex, bool IsResourcePath = false \)\r?$",
    lambda m: nl.join(helper) + nl + m.group(0), "texture path helper")
sub(r'^([\t ]+)if \( CubeTex \)//\|\| Format == TSF_RGBA16F \)\r?\n([\t ]+)TextureFileName \+= TEXT\("\.hdr" \);\r?\n([\t ]+)else\r?$',
    lambda m: m.group(0) + " if( GodotFabIsFloatTexture( Tex ) )// GodotFab: float textures as EXR" + nl + m.group(2) + 'TextureFileName += TEXT(".exr" );' + nl + m.group(3) + "else",
    "texture extension")
sub(r"^([\t ]+)if \(!IsUDIM \)\r?\n([\t ]+)Tex->Source\.GetMipData\( OutMipData, 0 \);\r?$",
    lambda m: m.group(1) + "if( GodotFabIsFloatTexture( Tex ) )// GodotFab: float textures as EXR" + nl + m.group(1) + "\treturn GodotFabSaveFloatTexture( Tex, TextureFileName );" + nl + m.group(0),
    "float texture save")
open(path, "w", newline="").write(src)
PY
		if [ "$(grep -c 'GodotFab: float textures as EXR' "$EXPORT_TO_UNITY")" != "3" ]; then
			echo "error: patching $EXPORT_TO_UNITY (float textures) failed" >&2
			exit 1
		fi
		echo "== Patched ExportToUnity.cpp: float textures saved as EXR"
	else
		echo "warning: could not find the texture extension code in $EXPORT_TO_UNITY; float textures stay 8-bit PNG" >&2
	fi
fi

# Patch 20: nested material function instances. Shader nodes, connections and the processing
# history are keyed by (expression, immediate function call). A function call inside a material
# function is one object, so when the outer function is called several times (Spruce Forest:
# PN_AnimationShader calls PN_WindAnimation once per wind level, PN_MultiBend six times) the
# nested calls collapse into one node set: every level read the same Pivot Painter pivot and the
# leaves turned about the wrong point (trees half empty). Each (parent call, nested call) pair
# now gets its own transient copy of the call, resolved wherever a call enters the stack.
# Calls at the material's root keep their original object, so shaders without nested functions
# are generated exactly as before.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: nested function call instances' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for nested function call instances"
	elif grep -q '^void GatherShaderNodes( UMaterialExpression\* Expression, UMaterialExpressionMaterialFunctionCall\* ParentFunctionCall, GodotShaderData& Data,' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		python3 - "$GODOT_SCENE" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, newline="").read()
nl = "\r\n" if "\r\n" in src else "\n"
MARK = "// GodotFab: nested function call instances"

def sub(pattern, repl, what, count=1):
    global src
    src, n = re.subn(pattern, repl, src, flags=re.M)
    if n != count:
        sys.exit("%s pattern matched %d times" % (what, n))

helper = [
    MARK,
    "static UMaterialExpressionMaterialFunctionCall* GodotFabResolveFunctionCall( UMaterialExpressionMaterialFunctionCall* Parent, UMaterialExpressionMaterialFunctionCall* Call )",
    "{",
    "\tstatic TMap<TPair<UMaterialExpressionMaterialFunctionCall*, UMaterialExpressionMaterialFunctionCall*>, UMaterialExpressionMaterialFunctionCall*> Instances;",
    "\tstatic TSet<UMaterialExpressionMaterialFunctionCall*> Copies;",
    "\tif( !Parent || !Call || Copies.Contains( Call ) )",
    "\t\treturn Call;",
    "\tconst TPair<UMaterialExpressionMaterialFunctionCall*, UMaterialExpressionMaterialFunctionCall*> Key( Parent, Call );",
    "\tif( UMaterialExpressionMaterialFunctionCall** Found = Instances.Find( Key ) )",
    "\t\treturn *Found;",
    "\t// Same function, inputs and outputs (links to the same expressions); only its identity differs.",
    "\tUMaterialExpressionMaterialFunctionCall* Copy = NewObject<UMaterialExpressionMaterialFunctionCall>( GetTransientPackage() );",
    "\tCopy->MaterialFunction = Call->MaterialFunction;",
    "\tCopy->FunctionInputs = Call->FunctionInputs;",
    "\tCopy->FunctionOutputs = Call->FunctionOutputs;",
    "\tCopy->Outputs = Call->Outputs;",
    "\tCopy->Material = Call->Material;",
    "\tCopy->Function = Call->Function;",
    "\tCopy->Desc = Call->Desc;",
    "\tCopy->MaterialExpressionEditorX = Call->MaterialExpressionEditorX;",
    "\tCopy->MaterialExpressionEditorY = Call->MaterialExpressionEditorY;",
    "\tCopy->AddToRoot();",
    "\tInstances.Add( Key, Copy );",
    "\tCopies.Add( Copy );",
    "\treturn Copy;",
    "}",
    "",
]
sub(r"^void GatherShaderNodes\( UMaterialExpression\* Expression, UMaterialExpressionMaterialFunctionCall\* ParentFunctionCall, GodotShaderData& Data,\r?$",
    lambda m: nl.join(helper) + nl + m.group(0), "resolver")
# GatherShaderNodes and GetShaderNode: nested in ParentFunctionCall.
sub(r"^(\t)UMaterialExpressionMaterialFunctionCall\* LocalFunctionCall = Cast<UMaterialExpressionMaterialFunctionCall>\( Expression \);\r?$",
    lambda m: m.group(0) + nl + m.group(1) + "LocalFunctionCall = GodotFabResolveFunctionCall( ParentFunctionCall, LocalFunctionCall );" + MARK,
    "gather/get node calls", 2)
# RouteExpressionAllCases: nested in the current call of the stack.
sub(r"^(\t)UMaterialExpressionMaterialFunctionCall\* FunctionCall = Cast<UMaterialExpressionMaterialFunctionCall>\( Expression \);\r?\n(\tif\( FunctionCall \)\r?\n\t\{\r?\n\t\tGetInputForFunctionCallOutput\( FunctionCall, RoutedInput\.OutputIndex, RoutedInput \);)",
    lambda m: m.group(0).split(nl, 1)[0] + nl + m.group(1) + "FunctionCall = GodotFabResolveFunctionCall( FunctionCallStackIn.Current(), FunctionCall );" + MARK + nl + m.group(2),
    "route calls")
# GatherNodesConnections: the expression itself and each input.
sub(r"^(\t)UMaterialExpressionMaterialFunctionCall\* FunctionCall = Cast<UMaterialExpressionMaterialFunctionCall>\( Expression \);\r?\n(\tif\( MaterialOutput->ExpressionInput && MaterialOutput->ExpressionInput->Expression == ExpressionBeforeRouting \))",
    lambda m: m.group(0).split(nl, 1)[0] + nl + m.group(1) + "FunctionCall = GodotFabResolveFunctionCall( FunctionCallStack.Current(), FunctionCall );" + MARK + nl + m.group(2),
    "connection calls")
sub(r"^(\t+)UMaterialExpressionMaterialFunctionCall\* InputFunctionCall = Cast<UMaterialExpressionMaterialFunctionCall>\( InputExpression \);\r?$",
    lambda m: m.group(0) + nl + m.group(1) + "InputFunctionCall = GodotFabResolveFunctionCall( FunctionCallStack.Current(), InputFunctionCall );" + MARK,
    "connection input calls")
open(path, "w", newline="").write(src)
PY
		if [ "$(grep -c 'GodotFab: nested function call instances' "$GODOT_SCENE")" != "6" ]; then
			echo "error: patching $GODOT_SCENE (nested function calls) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: nested function call instances"
	else
		echo "warning: could not find GatherShaderNodes in $GODOT_SCENE; nested material functions stay shared" >&2
	fi
fi

# Patch 21: Clamp mode and Sine/Cosine/Tangent period. Unreal's Clamp has a mode: "Clamp Min"
# is max(x, Min) and "Clamp Max" is min(x, Max), with the unused default left in the asset
# (Pivot Painter 2's extent decode: Clamp Min 8, Max 1). The exporter wrote clamp(x, 8, 1),
# always 1 cm, so every wind level swung its branches rigidly (lower branches far, the top
# barely). The unused bound now gets +-1e20. Unreal's trig nodes compute f(x * 2pi / Period)
# when Period > 0 (default 1: input in turns); the exporter wrote f(x), so Spruce Forest's
# WindDirection (degrees / 360) barely turned the wind. Those nodes become expressions with
# the scale.
if [ -f "$GODOT_SCENE" ]; then
	if grep -q 'GodotFab: clamp mode and trig period' "$GODOT_SCENE"; then
		echo "== GodotScene.cpp already patched for Clamp mode and trig period"
	elif grep -qF 'FVector4 DefaultValue3( Clamp->MaxDefault, Clamp->MaxDefault, Clamp->MaxDefault, Clamp->MaxDefault );' "$GODOT_SCENE"; then
		[ -f "$GODOT_SCENE.godotfab-orig" ] || cp -f "$GODOT_SCENE" "$GODOT_SCENE.godotfab-orig"
		python3 - "$GODOT_SCENE" <<'PY' || exit 1
import re, sys
path = sys.argv[1]
src = open(path, newline="").read()
nl = "\r\n" if "\r\n" in src else "\n"
MARK = "// GodotFab: clamp mode and trig period"

def sub(pattern, repl, what):
    global src
    src, n = re.subn(pattern, repl, src, flags=re.M)
    if n != 1:
        sys.exit("%s pattern matched %d times" % (what, n))

sub(r"^(\t+)FVector4 DefaultValue3\( Clamp->MaxDefault, Clamp->MaxDefault, Clamp->MaxDefault, Clamp->MaxDefault \);\r?$",
    lambda m: m.group(0) + nl + m.group(1) + "if( Clamp->ClampMode == CMODE_ClampMin )" + MARK + nl +
              m.group(1) + "\tDefaultValue3 = FVector4( 1e20f, 1e20f, 1e20f, 1e20f );" + nl +
              m.group(1) + "else if( Clamp->ClampMode == CMODE_ClampMax )" + nl +
              m.group(1) + "\tDefaultValue2 = FVector4( -1e20f, -1e20f, -1e20f, -1e20f );",
    "clamp defaults")
for cls, var, gff, fn in (("Sine", "Sine", "GFF_SIN", "sin"), ("Cosine", "Cosine", "GFF_COS", "cos"), ("Tangent", "Tangent", "GFF_TAN", "tan")):
    sub(r"^(\t+)if\( %s \)\r?\n(\t+)\{\r?\n(\t+)return GenerateFloatFuncNode\( %s, 0\.0f, Params \);\r?$" % (var, gff),
        lambda m, var=var, fn=fn, gff=gff: (m.group(1) + "if( %s )" % var + nl + m.group(2) + "{" + nl +
            m.group(3) + "if( %s->Period > 0.0f && FMath::Abs( %s->Period - 2.0f * PI ) > 1e-4f )%s" % (var, var, MARK) + nl +
            m.group(3) + "{" + nl +
            m.group(3) + "\tsnprintf( Text, sizeof( Text ), \"//%s:%%d(%%s) Period %%f\\noutput0 = %s( input0 * %%.9f );\\n\", Subresource->ID, Subresource->GetFunctionCallName().c_str(), %s->Period, 2.0 * PI / %s->Period );" % (var, fn, var, var) + nl +
            m.group(3) + "\treturn GenerateShaderExpression( GSVT_FLOAT, GSVT_FLOAT, GSVT_FLOAT, Text, GSVT_FLOAT, Params, Subresource );" + nl +
            m.group(3) + "}" + nl +
            m.group(3) + "return GenerateFloatFuncNode( %s, 0.0f, Params );" % gff),
        "%s period" % cls)
open(path, "w", newline="").write(src)
PY
		if [ "$(grep -c 'GodotFab: clamp mode and trig period' "$GODOT_SCENE")" != "4" ]; then
			echo "error: patching $GODOT_SCENE (Clamp mode and trig period) failed" >&2
			exit 1
		fi
		echo "== Patched GodotScene.cpp: Clamp Min/Max modes and Sine/Cosine/Tangent periods"
	else
		echo "warning: could not find the Clamp code in $GODOT_SCENE; Clamp Min/Max modes and trig periods are ignored (the Godot importer fixes Clamp Min)" >&2
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
