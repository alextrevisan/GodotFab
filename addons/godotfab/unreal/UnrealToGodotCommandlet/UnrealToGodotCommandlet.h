// GodotFab - headless entry point for the UnrealToGodot plugin.
// Copied into Plugins/UnrealToGodot/Source/UnrealToGodot/Public/ by addons/godotfab/unreal/install_commandlet.sh

#pragma once

#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "UnrealToGodotCommandlet.generated.h"

/**
 * Runs the UnrealToGodot exporter without the editor UI.
 *
 * Usage (the module loads in the PostEngineInit phase, so the commandlet must be
 * addressed as Module.Class):
 *   UnrealEditor-Cmd <uproject> -run=UnrealToGodot.UnrealToGodot
 *       -ContentPath=/Game/Pack/Folder [-Map=/Game/Pack/Maps/Overview]
 *       -Output=/abs/output/dir [-SkinnedAsStatic] [-NaniteOriginal] [-NoTextures] [-NoPhysics]
 *       -unattended -nopause -nosplash -AllowCommandletRendering
 *
 * With -Map the map is loaded and exported as is. Without -Map a new empty map is
 * created and one StaticMeshActor / SkeletalMeshActor is spawned for every mesh asset
 * found under -ContentPath, laid out in a grid spaced by the mesh bounds.
 *
 * On success "<Output>/godotfab_done.txt" is written, the last log line is
 * "GodotFab: export finished" and the process exits with 0; any failure logs
 * "GodotFab: export failed: <reason>" and exits with 1.
 */
UCLASS()
class UUnrealToGodotCommandlet : public UCommandlet
{
	GENERATED_BODY()

public:
	UUnrealToGodotCommandlet();

	virtual int32 Main( const FString& Params ) override;
};
