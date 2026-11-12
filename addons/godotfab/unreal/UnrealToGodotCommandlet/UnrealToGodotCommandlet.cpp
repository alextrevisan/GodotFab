// GodotFab - headless entry point for the UnrealToGodot plugin.

#include "UnrealToGodotCommandlet.h"

#include "Misc/Parse.h"
#include "Misc/Paths.h"
#include "Misc/FileHelper.h"
#include "HAL/FileManager.h"
#include "Modules/ModuleManager.h"
#include "Editor.h"
#include "FileHelpers.h"
#include "Engine/World.h"
#include "Engine/StaticMesh.h"
#include "Engine/SkeletalMesh.h"
#include "Engine/StaticMeshActor.h"
#include "Animation/SkeletalMeshActor.h"
#include "Components/StaticMeshComponent.h"
#include "Components/SkeletalMeshComponent.h"
#include "Components/MeshComponent.h"
#include "SceneInterface.h"
#include "WorldPartition/WorldPartition.h"
#include "WorldPartition/LoaderAdapter/LoaderAdapterShape.h"
#include "AssetRegistry/AssetRegistryModule.h"
#include "AssetRegistry/IAssetRegistry.h"
#include "AssetRegistry/ARFilter.h"
#include "UObject/Package.h"
#include "EngineUtils.h"
#include "LandscapeGizmoActiveActor.h"
#include "PaperTileMapComponent.h"
#include "PaperSpriteComponent.h"
#include "PaperGroupedSpriteComponent.h"
#include "PaperFlipbookComponent.h"
#include "Elements/Actor/ActorElementEditorViewportInteractionCustomization.h"
#include "Engine/SkyLight.h"
#include "Components/SkyLightComponent.h"
#include "Engine/ExponentialHeightFog.h"
#include "Components/ExponentialHeightFogComponent.h"
#include "Engine/PostProcessVolume.h"
#include "LandscapeProxy.h"
#include "Engine/Texture.h"
#include "UObject/UObjectIterator.h"
#include "Materials/Material.h"
#include "Materials/MaterialInstance.h"
#include "Materials/MaterialExpression.h"
#include "Materials/MaterialExpressionTextureBase.h"
#include "Materials/MaterialExpressionTextureSample.h"
#include "Materials/MaterialExpressionTextureSampleParameter.h"
#include "Materials/MaterialExpressionTextureObject.h"
#include "Materials/MaterialExpressionTextureObjectParameter.h"

#include "UTXModule.h"
#include "BaseScene.h"
#include "GodotScene.h"
#include "ExportActor.h"

// Defined in UTXModule.cpp but not declared in any header. The default argument
// belongs to the definition, so it must not be repeated here.
void InstantiateExporter( EngineType Engine );
// Defined in ExportActor.cpp. When true AExportActor::DoExport rotates the actors through
// GEditor->ApplyDeltaToActor, which asserts in commandlets (GLevelEditorModeTools()).
extern bool DoRotateOnExport;

namespace
{
	int32 Fail( const FString& Reason )
	{
		UE_LOG( LogTemp, Error, TEXT( "GodotFab: export failed: %s" ), *Reason );
		return 1;
	}

	// Godot stores Color properties as shown in the inspector (sRGB), so an Unreal FColor
	// (sRGB bytes) maps channel / 255, without FLinearColor's gamma conversion.
	FString GodotColor( const FLinearColor& C )
	{
		return FString::Printf( TEXT( "Color(%f, %f, %f, 1)" ), C.R, C.G, C.B );
	}

	// Godot's CameraAttributesPractical computes the exposure of physical light units from
	// exposure_sensitivity (ISO) with a fixed f/16 and 1/100 s, i.e. EV100 = log2(25600) -
	// log2(ISO / 100). Unreal's EV100 comes from the post process camera settings.
	constexpr double GodotPracticalEV100AtISO100 = 14.643856189774724; // log2(16 * 16 * 100)

	double ISOForEV100( double EV100 )
	{
		return 100.0 * FMath::Pow( 2.0, GodotPracticalEV100AtISO100 - EV100 );
	}

	struct FGodotExposure
	{
		bool bAuto = true;
		double EV100 = 10.0;     // exposure the scene is shown at (manual, or the auto centre)
		double MinEV100 = -10.0; // auto exposure range
		double MaxEV100 = 20.0;
	};

	// Unreal's exposure (FPostProcessSettings fields hold Unreal's defaults when not
	// overridden): manual = log2(N^2 * shutter * 100 / ISO) with the physical camera,
	// 0 without it; the exposure compensation (bias) brightens, so it is subtracted.
	FGodotExposure ComputeExposure( const FPostProcessSettings* S )
	{
		FGodotExposure E;
		const FPostProcessSettings Defaults;
		if( !S )
			S = &Defaults;
		const double Bias = S->AutoExposureBias;
		const double Physical = S->AutoExposureApplyPhysicalCameraExposure
			? FMath::Log2( (double)S->DepthOfFieldFstop * S->DepthOfFieldFstop * S->CameraShutterSpeed * 100.0 / FMath::Max( 1.0f, S->CameraISO ) )
			: 0.0;
		E.bAuto = S->AutoExposureMethod != AEM_Manual;
		E.MinEV100 = S->AutoExposureMinBrightness - Bias;
		E.MaxEV100 = S->AutoExposureMaxBrightness - Bias;
		E.EV100 = E.bAuto ? FMath::Clamp( Physical - Bias, E.MinEV100, E.MaxEV100 ) : Physical - Bias;
		return E;
	}

	// Godot multiplies light and sky energies by the exposure normalization but not the
	// volumetric fog emission, which Unreal does expose: scale it here.
	double ExposureNormalization( double EV100 )
	{
		return 1.0 / ( 1.2 * FMath::Pow( 2.0, EV100 ) );
	}

	void WriteGodotCameraAttributes( const FGodotExposure& E, const FString& Output )
	{
		FString Text = TEXT( "[gd_resource type=\"CameraAttributesPractical\" format=3 uid=\"uid://4cfoi3npjx37\"]\n\n[resource]\n" );
		Text += FString::Printf( TEXT( "exposure_sensitivity = %f\n" ), ISOForEV100( E.EV100 ) );
		if( E.bAuto )
		{
			// A higher EV100 is a darker exposure, i.e. a lower sensitivity.
			Text += FString::Printf( TEXT( "auto_exposure_enabled = true\nauto_exposure_min_sensitivity = %f\nauto_exposure_max_sensitivity = %f\n" ),
				ISOForEV100( E.MaxEV100 ), ISOForEV100( E.MinEV100 ) );
		}
		if( FFileHelper::SaveStringToFile( Text, *( Output + TEXT( "CameraAttributes.tres" ) ) ) )
			UE_LOG( LogTemp, Display, TEXT( "GodotFab: CameraAttributes from the level (%s exposure, EV100 %.2f)" ), E.bAuto ? TEXT( "auto" ) : TEXT( "manual" ), E.EV100 );
	}

	// The exporter writes a fixed WorldEnvironment.tscn (a bright procedural sky as
	// background and ambient light, no fog). Rewrite it from the level: SkyLight,
	// ExponentialHeightFog (+ volumetric fog) and the unbound PostProcessVolume.
	// Unreal densities are per 1000 cm, Godot's per metre: Godot = Unreal * 0.1.
	void WriteGodotEnvironment( UWorld* World, const FString& Output )
	{
		USkyLightComponent* Sky = nullptr;
		UExponentialHeightFogComponent* Fog = nullptr;
		float FogZ = 0.0f;
		float AORadius = -1.0f;
		const FPostProcessSettings* Exposure = nullptr;
		float ExposurePriority = 0.0f;
		for( TActorIterator<AActor> It( World ); It; ++It )
		{
			if( ASkyLight* SkyActor = Cast<ASkyLight>( *It ) )
			{
				if( !Sky && SkyActor->GetLightComponent() && SkyActor->GetLightComponent()->IsVisible() )
					Sky = SkyActor->GetLightComponent();
			}
			else if( AExponentialHeightFog* FogActor = Cast<AExponentialHeightFog>( *It ) )
			{
				if( !Fog && FogActor->GetComponent() && FogActor->GetComponent()->IsVisible() )
				{
					Fog = FogActor->GetComponent();
					FogZ = FogActor->GetActorLocation().Z;
				}
			}
			else if( APostProcessVolume* PPV = Cast<APostProcessVolume>( *It ) )
			{
				if( PPV->bUnbound && PPV->bEnabled && PPV->Settings.bOverride_AmbientOcclusionRadius )
					AORadius = PPV->Settings.AmbientOcclusionRadius;
				if( PPV->bUnbound && PPV->bEnabled && ( !Exposure || PPV->Priority > ExposurePriority ) )
				{
					Exposure = &PPV->Settings;
					ExposurePriority = PPV->Priority;
				}
			}
		}
		const FGodotExposure Camera = ComputeExposure( Exposure );

		FString Env;
		if( Sky )
		{
			Env += FString::Printf( TEXT( "background_mode = 2\nbackground_intensity = %f\nsky = SubResource(\"Sky_ye75x\")\nambient_light_source = 3\n" ), 9716.98f * Sky->Intensity );
		}
		else
		{
			// No SkyLight in the level: no sky light at all (closed interiors stay dark).
			const FLinearColor Bg = Fog ? Fog->FogInscatteringLuminance : FLinearColor::Black;
			Env += FString::Printf( TEXT( "background_mode = 1\nbackground_color = %s\nbackground_intensity = 0.0\nambient_light_source = 1\nreflected_light_source = 1\n" ), *GodotColor( Bg ) );
		}
		Env += TEXT( "tonemap_mode = 3\nglow_enabled = true\nssr_enabled = true\nssao_enabled = true\n" );
		if( AORadius > 0.0f )
			Env += FString::Printf( TEXT( "ssao_radius = %f\n" ), AORadius / 100.0f );
		Env += TEXT( "sdfgi_enabled = true\nsdfgi_use_occlusion = true\n" );
		if( !Sky )
			Env += TEXT( "sdfgi_read_sky_light = false\n" );
		if( Fog )
		{
			const float Density = Fog->FogDensity * 0.1f;
			Env += FString::Printf( TEXT( "fog_enabled = true\nfog_light_color = %s\nfog_light_energy = 0.25\nfog_density = %f\n" ), *GodotColor( Fog->FogInscatteringLuminance ), Density );
			if( Fog->FogHeightFalloff > 0.0f )
				Env += FString::Printf( TEXT( "fog_height = %f\nfog_height_density = %f\n" ), FogZ / 100.0f, Fog->FogHeightFalloff * 0.1f );
			if( Fog->bEnableVolumetricFog )
			{
				Env += FString::Printf( TEXT( "volumetric_fog_enabled = true\nvolumetric_fog_density = %f\nvolumetric_fog_albedo = %s\nvolumetric_fog_emission = %s\nvolumetric_fog_anisotropy = %f\nvolumetric_fog_length = %f\n" ),
					Density * Fog->VolumetricFogExtinctionScale, *GodotColor( FLinearColor( Fog->VolumetricFogAlbedo.R / 255.0f, Fog->VolumetricFogAlbedo.G / 255.0f, Fog->VolumetricFogAlbedo.B / 255.0f ) ), *GodotColor( Fog->VolumetricFogEmissive * (float)ExposureNormalization( Camera.EV100 ) ),
					Fog->VolumetricFogScatteringDistribution, Fog->VolumetricFogDistance / 100.0f );
			}
		}

		const FString Text = FString( TEXT( "[gd_scene format=3 uid=\"uid://dbbeq4jwg3egn\"]\n\n" ) )
			+ TEXT( "[ext_resource type=\"CameraAttributesPractical\" uid=\"uid://4cfoi3npjx37\" path=\"res://CameraAttributes.tres\" id=\"1_q0a8c\"]\n\n" )
			+ TEXT( "[sub_resource type=\"ProceduralSkyMaterial\" id=\"ProceduralSkyMaterial_06w47\"]\nsky_horizon_color = Color(0.66224277, 0.6717428, 0.6867428, 1)\nground_horizon_color = Color(0.66224277, 0.6717428, 0.6867428, 1)\n\n" )
			+ TEXT( "[sub_resource type=\"Sky\" id=\"Sky_ye75x\"]\nsky_material = SubResource(\"ProceduralSkyMaterial_06w47\")\n\n" )
			+ TEXT( "[sub_resource type=\"Environment\" id=\"Environment_7y8hs\"]\n" ) + Env
			+ TEXT( "\n[node name=\"Node3D\" type=\"Node3D\"]\n\n[node name=\"WorldEnvironment\" type=\"WorldEnvironment\" parent=\".\"]\nenvironment = SubResource(\"Environment_7y8hs\")\ncamera_attributes = ExtResource(\"1_q0a8c\")\n" );
		WriteGodotCameraAttributes( Camera, Output );
		if( FFileHelper::SaveStringToFile( Text, *( Output + TEXT( "WorldEnvironment.tscn" ) ) ) )
			UE_LOG( LogTemp, Display, TEXT( "GodotFab: WorldEnvironment from the level (sky light: %s, fog: %s, volumetric fog: %s)" ),
				Sky ? TEXT( "yes" ) : TEXT( "no" ), Fog ? TEXT( "yes" ) : TEXT( "no" ), ( Fog && Fog->bEnableVolumetricFog ) ? TEXT( "yes" ) : TEXT( "no" ) );
	}

	struct FMeshEntry
	{
		UStaticMesh* StaticMesh = nullptr;
		USkeletalMesh* SkeletalMesh = nullptr;
		FBoxSphereBounds Bounds;
		FString Name;
	};

	bool SpawnMeshActor( UWorld* World, const FMeshEntry& Entry, const FVector& Location )
	{
		FTransform Transform( Location );
		FActorSpawnParameters SpawnParams;
		SpawnParams.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;

		if( Entry.StaticMesh )
		{
			AStaticMeshActor* Actor = World->SpawnActor<AStaticMeshActor>( AStaticMeshActor::StaticClass(), Transform, SpawnParams );
			if( !Actor )
			{
				return false;
			}
			Actor->GetStaticMeshComponent()->SetStaticMesh( Entry.StaticMesh );
			Actor->SetActorLabel( Entry.Name );
			return true;
		}

		if( Entry.SkeletalMesh )
		{
			ASkeletalMeshActor* Actor = World->SpawnActor<ASkeletalMeshActor>( ASkeletalMeshActor::StaticClass(), Transform, SpawnParams );
			if( !Actor )
			{
				return false;
			}
			USkeletalMeshComponent* Component = Actor->GetSkeletalMeshComponent();
			// A map loaded by a commandlet gets a scene without a renderer: creating the
			// skeletal mesh's render state there asserts (SkeletalRenderGPUSkin.cpp, "Scene
			// cannot be null"). The exporter only reads the asset and the transform, so set the
			// mesh with the component unregistered and leave it that way.
			const bool bHasRenderer = World->Scene && World->Scene->GetSkeletalMeshUpdater();
			if( !bHasRenderer && Component->IsRegistered() )
			{
				Component->UnregisterComponent();
			}
			Component->SetSkeletalMeshAsset( Entry.SkeletalMesh );
			if( !bHasRenderer )
			{
				Component->UpdateComponentToWorld();
			}
			Actor->SetActorLabel( Entry.Name );
			return true;
		}

		return false;
	}

	// Spawns every StaticMesh/SkeletalMesh under the content paths in a grid starting at
	// Origin, skipping the meshes in Skip (already placed in the level). Returns the
	// number of actors spawned.
	int32 SpawnMeshesFromContentPath( UWorld* World, const TArray<FString>& ContentPaths, const FVector& Origin = FVector::ZeroVector, const TSet<UObject*>* Skip = nullptr )
	{
		const FString ContentPath = FString::Join( ContentPaths, TEXT( "," ) );
		FAssetRegistryModule& AssetRegistryModule = FModuleManager::LoadModuleChecked<FAssetRegistryModule>( "AssetRegistry" );
		IAssetRegistry& AssetRegistry = AssetRegistryModule.Get();

		// Commandlets do not necessarily have a populated registry: scan the folder synchronously.
		AssetRegistry.ScanPathsSynchronous( ContentPaths, true );

		FARFilter Filter;
		for( const FString& Path : ContentPaths )
		{
			Filter.PackagePaths.Add( FName( *Path ) );
		}
		Filter.bRecursivePaths = true;
		Filter.ClassPaths.Add( UStaticMesh::StaticClass()->GetClassPathName() );
		Filter.ClassPaths.Add( USkeletalMesh::StaticClass()->GetClassPathName() );
		Filter.bRecursiveClasses = true;

		TArray<FAssetData> Assets;
		AssetRegistry.GetAssets( Filter, Assets );
		Assets.Sort( []( const FAssetData& A, const FAssetData& B )
		{
			return A.GetObjectPathString() < B.GetObjectPathString();
		} );

		UE_LOG( LogTemp, Display, TEXT( "GodotFab: found %d mesh assets under %s" ), Assets.Num(), *ContentPath );

		TArray<FMeshEntry> Entries;
		Entries.Reserve( Assets.Num() );
		for( int32 Index = 0; Index < Assets.Num(); ++Index )
		{
			FAssetData& Asset = Assets[ Index ];
			UE_LOG( LogTemp, Log, TEXT( "GodotFab: Loading Mesh %s (%d/%d)" ), *Asset.GetObjectPathString(), Index + 1, Assets.Num() );

			UObject* Object = Asset.GetAsset();
			if( Skip && Object && Skip->Contains( Object ) )
			{
				continue;
			}
			FMeshEntry Entry;
			if( UStaticMesh* StaticMesh = Cast<UStaticMesh>( Object ) )
			{
				Entry.StaticMesh = StaticMesh;
				Entry.Bounds = StaticMesh->GetBounds();
			}
			else if( USkeletalMesh* SkeletalMesh = Cast<USkeletalMesh>( Object ) )
			{
				Entry.SkeletalMesh = SkeletalMesh;
				Entry.Bounds = SkeletalMesh->GetBounds();
			}
			else
			{
				UE_LOG( LogTemp, Warning, TEXT( "GodotFab: could not load %s" ), *Asset.GetObjectPathString() );
				continue;
			}
			Entry.Name = Object->GetName();
			Entries.Add( Entry );
		}

		const int32 Count = Entries.Num();
		if( Count == 0 )
		{
			return 0;
		}

		// Grid: roughly square, each row as deep as its deepest mesh, every mesh resting on Z=0.
		const int32 Columns = FMath::Max( 1, FMath::CeilToInt( FMath::Sqrt( (float)Count ) ) );
		const double Padding = 100.0; // 1 m between bounding boxes
		double CursorY = 0.0;
		int32 Spawned = 0;

		for( int32 RowStart = 0; RowStart < Count; RowStart += Columns )
		{
			const int32 RowEnd = FMath::Min( Count, RowStart + Columns );

			double RowDepth = 0.0;
			for( int32 Index = RowStart; Index < RowEnd; ++Index )
			{
				RowDepth = FMath::Max( RowDepth, Entries[ Index ].Bounds.BoxExtent.Y );
			}
			const double RowCenterY = CursorY + RowDepth;

			double CursorX = 0.0;
			for( int32 Index = RowStart; Index < RowEnd; ++Index )
			{
				const FBoxSphereBounds& Bounds = Entries[ Index ].Bounds;
				const double CenterX = CursorX + Bounds.BoxExtent.X;
				const FVector Location(
					Origin.X + CenterX - Bounds.Origin.X,
					Origin.Y + RowCenterY - Bounds.Origin.Y,
					Origin.Z + Bounds.BoxExtent.Z - Bounds.Origin.Z );

				if( SpawnMeshActor( World, Entries[ Index ], Location ) )
				{
					++Spawned;
				}
				else
				{
					UE_LOG( LogTemp, Warning, TEXT( "GodotFab: could not spawn an actor for %s" ), *Entries[ Index ].Name );
				}

				CursorX += 2.0 * Bounds.BoxExtent.X + Padding;
			}

			CursorY += 2.0 * RowDepth + Padding;
		}

		return Spawned;
	}

	// Maps of game templates spawn their characters and weapons from Blueprints at run
	// time, so the level alone misses most of the pack. Add the pack's meshes that no
	// component of the level uses, in a grid beside the level (+Y, 20 m away).
	int32 AddUnplacedPackMeshes( UWorld* World, const TArray<FString>& ContentPath )
	{
		TSet<UObject*> Used;
		FBox LevelBox( ForceInit );
		for( TActorIterator<AActor> It( World ); It; ++It )
		{
			TArray<UActorComponent*> Components;
			It->GetComponents( UMeshComponent::StaticClass(), Components );
			for( UActorComponent* Component : Components )
			{
				if( UStaticMeshComponent* SMC = Cast<UStaticMeshComponent>( Component ) )
				{
					if( SMC->GetStaticMesh() )
						Used.Add( SMC->GetStaticMesh() );
				}
				else if( USkeletalMeshComponent* SKC = Cast<USkeletalMeshComponent>( Component ) )
				{
					if( SKC->GetSkeletalMeshAsset() )
						Used.Add( SKC->GetSkeletalMeshAsset() );
				}
				if( UPrimitiveComponent* Prim = Cast<UPrimitiveComponent>( Component ) )
				{
					const FBox Box = Prim->Bounds.GetBox();
					if( Box.IsValid && Box.GetExtent().GetMax() < 1.0e6 )
						LevelBox += Box;
				}
			}
		}
		const FVector Origin = LevelBox.IsValid ? FVector( LevelBox.Min.X, LevelBox.Max.Y + 2000.0, LevelBox.Min.Z ) : FVector::ZeroVector;
		const int32 Added = SpawnMeshesFromContentPath( World, ContentPath, Origin, &Used );
		UE_LOG( LogTemp, Display, TEXT( "GodotFab: added %d pack meshes not placed in the level (%d already used)" ), Added, Used.Num() );
		return Added;
	}
}

namespace
{
	/**
	 * Commandlet-safe copy of AExportActor::RotateActorsForExport (Godot branch): the same
	 * delta rotation about the world origin, applied through the static element helper
	 * instead of GEditor->ApplyDeltaToActor, which needs the level editor mode tools.
	 */
	void RotateActorsForExport( UWorld* World, bool bForward )
	{
		GEditor->SelectNone( false, true, false );

		for( TActorIterator<AActor> It( World ); It; ++It )
		{
			AActor* Actor = *It;
			if( Cast<ALandscapeGizmoActiveActor>( Actor ) )
			{
				continue;
			}
			const bool bIs2DActor =
				Actor->GetComponentByClass( UPaperTileMapComponent::StaticClass() ) ||
				Actor->GetComponentByClass( UPaperSpriteComponent::StaticClass() ) ||
				Actor->GetComponentByClass( UPaperGroupedSpriteComponent::StaticClass() ) ||
				Actor->GetComponentByClass( UPaperFlipbookComponent::StaticClass() );
			if( bIs2DActor )
			{
				continue;
			}
			// Don't modify children
			if( Actor->GetParentActor() )
			{
				continue;
			}

			// Prevent construction scripts from messing up transforms in some cases
			Actor->bActorSeamlessTraveled = 1;

			const FVector DeltaDrag( 0, 0, 0 );
			const FRotator DeltaRot( 0.0, 0.0, bForward ? 90.0 : -90.0 );
			FVector DeltaScale( 0, 0, 0 );
			FActorElementEditorViewportInteractionCustomization::ApplyDeltaToActor(
				Actor, true, &DeltaDrag, &DeltaRot, &DeltaScale, FVector::ZeroVector, FInputDeviceState() );
		}
	}
}

namespace
{
	// Unreal samples Pivot Painter textures (one value per branch, the parent index in the
	// alpha bits) with Nearest filtering, but the exporter writes every Godot texture
	// parameter with linear filtering: blended texels send branches flying. Lists every
	// loaded texture whose filter is Nearest (package path without the /Game mount, as the
	// exporter lays out files) so the GodotFab importer can set the parameters that use them
	// to nearest.
	void WriteNearestTextures( const FString& Output )
	{
		TArray< FString > Lines;
		for( TObjectIterator< UTexture > It; It; ++It )
		{
			UTexture* Tex = *It;
			if( !Tex || Tex->Filter != TF_Nearest || Tex->GetOutermost() == GetTransientPackage() )
				continue;
			FString Path = Tex->GetOutermost()->GetName();
			if( Path.StartsWith( TEXT( "/Game/" ) ) )
				Path.RightChopInline( 6 );
			else
				Path.RightChopInline( 1 );
			Lines.AddUnique( Path );
		}
		Lines.Sort();
		FFileHelper::SaveStringArrayToFile( Lines, *( Output + TEXT( "godotfab_nearest_textures.txt" ) ) );
		UE_LOG( LogTemp, Display, TEXT( "GodotFab: %d textures with Nearest filtering" ), Lines.Num() );
	}

	// Exposes UMaterial::RecursiveGetExpressionChain (protected): the public
	// GetTexturesInPropertyChain does not follow materials that use Material Attributes.
	struct FMaterialChainAccess : UMaterial
	{
		using UMaterial::RecursiveGetExpressionChain;
	};

	FString TextureExportPath( UTexture* Tex )
	{
		FString Path = Tex->GetOutermost()->GetName();
		if( Path.StartsWith( TEXT( "/Game/" ) ) )
			Path.RightChopInline( 6 );
		else
			Path.RightChopInline( 1 );
		return Path;
	}

	// The texture a sample node reads in Material: the instance's value of its parameter (or
	// of the Texture Object Parameter wired to it), else the node's own texture.
	UTexture* SampledTexture( UMaterialInterface* Material, UMaterialExpressionTextureBase* Sample )
	{
		FName Param;
		if( UMaterialExpressionTextureSampleParameter* P = Cast<UMaterialExpressionTextureSampleParameter>( Sample ) )
			Param = P->ParameterName;
		else if( UMaterialExpressionTextureSample* S = Cast<UMaterialExpressionTextureSample>( Sample ) )
		{
			if( UMaterialExpressionTextureSampleParameter* P2 = Cast<UMaterialExpressionTextureSampleParameter>( S->TextureObject.Expression ) )
			{
				Param = P2->ParameterName;
				Sample = P2;
			}
			else if( UMaterialExpressionTextureBase* O = Cast<UMaterialExpressionTextureBase>( S->TextureObject.Expression ) )
				Sample = O;
		}
		UTexture* Tex = nullptr;
		if( !Param.IsNone() && Material->GetTextureParameterValue( Param, Tex ) && Tex )
			return Tex;
		return Sample->Texture;
	}

	// Alpha tested foliage loses its leaves at a distance: mipmaps average the opacity
	// below the clip value. Lists, for every masked material, the texture channel that
	// feeds Opacity Mask and the clip value ("<texture>\t<R|G|B|A>\t<clip>"), so the
	// GodotFab importer can preserve alpha test coverage in that texture's mipmaps.
	void WriteOpacityTextures( const FString& Output )
	{
		static const TCHAR* Channels[] = { TEXT( "R" ), TEXT( "G" ), TEXT( "B" ), TEXT( "A" ) };
		auto Chain = &FMaterialChainAccess::RecursiveGetExpressionChain;
		TArray< FString > Lines;
		for( TObjectIterator< UMaterialInterface > It; It; ++It )
		{
			UMaterialInterface* Material = *It;
			if( !Material || Material->GetOutermost() == GetTransientPackage() || Material->GetBlendMode() != BLEND_Masked )
				continue;
			UMaterial* Base = Material->GetMaterial();
			if( !Base )
				continue;
			FExpressionInput* Start = Base->GetExpressionInputForProperty( Base->bUseMaterialAttributes ? MP_MaterialAttributes : MP_OpacityMask );
			if( !Start || !Start->Expression )
				continue;
			FStaticParameterSet Statics;
			Material->GetStaticParameterValues( Statics );
			TSet< FExpressionInput* > Processed;
			Processed.Add( Start );
			TSet< UMaterialExpression* > Expressions;
			( Base->*Chain )( Start->Expression, Processed, Expressions, &Statics, ERHIFeatureLevel::Num, EMaterialQualityLevel::Num,
				ERHIShadingPath::Num, SF_Pixel, MP_OpacityMask, true );
			// Channel each texture sample is read through by the chain: output 1..4 is R..A,
			// a masked output 0 with a single channel counts as that channel.
			TMap< UMaterialExpressionTextureBase*, TSet< int32 > > Reads;
			for( UMaterialExpression* Expression : Expressions )
			{
				if( !Expression )
					continue;
				for( FExpressionInputIterator In{ Expression }; In; ++In )
				{
					UMaterialExpressionTextureBase* Sample = Cast<UMaterialExpressionTextureBase>( In->Expression );
					// Texture Object nodes only pass the texture on to a sample node.
					if( !Sample || !Expressions.Contains( Sample ) || Sample->IsA<UMaterialExpressionTextureObject>() || Sample->IsA<UMaterialExpressionTextureObjectParameter>() )
						continue;
					int32 Channel = -1;
					if( In->OutputIndex >= 1 && In->OutputIndex <= 4 )
						Channel = In->OutputIndex - 1;
					else if( In->Mask && In->MaskR + In->MaskG + In->MaskB + In->MaskA == 1 )
						Channel = In->MaskR ? 0 : In->MaskG ? 1 : In->MaskB ? 2 : 3;
					Reads.FindOrAdd( Sample ).Add( Channel );
				}
			}
			const float Clip = Material->GetOpacityMaskClipValue();
			for( const TPair< UMaterialExpressionTextureBase*, TSet< int32 > >& Read : Reads )
			{
				UTexture* Tex = SampledTexture( Material, Read.Key );
				if( !Tex )
					continue;
				for( int32 Channel : Read.Value )
				{
					// -1: read as a color, the importer leaves the texture alone.
					Lines.AddUnique( FString::Printf( TEXT( "%s\t%s\t%.4f" ), *TextureExportPath( Tex ), Channel < 0 ? TEXT( "RGB" ) : Channels[ Channel ], Clip ) );
				}
			}
		}
		Lines.Sort();
		FFileHelper::SaveStringArrayToFile( Lines, *( Output + TEXT( "godotfab_opacity_textures.txt" ) ) );
		UE_LOG( LogTemp, Display, TEXT( "GodotFab: %d texture channels feed Opacity Mask" ), Lines.Num() );
	}
}

UUnrealToGodotCommandlet::UUnrealToGodotCommandlet()
{
	// Must be a client: with GIsClient false, FRendererModule::AllocateScene gives every
	// world an FNULLSceneInterface (no GPU skinning updater), and registering a skeletal mesh
	// component then asserts in SkeletalRenderGPUSkin.cpp ("Scene cannot be null").
	IsClient = true;
	IsServer = false;
	IsEditor = true;
	LogToConsole = true;
	ShowErrorCount = true;
}

namespace
{
	// World Partition maps keep their actors in external packages that LoadMap does not
	// load: load every actor of the world, as "Load All" in the editor's World Partition
	// panel does. The returned adapter keeps them loaded while it lives.
	TUniquePtr<FLoaderAdapterShape> LoadWorldPartitionActors( UWorld* World )
	{
		if( !World->GetWorldPartition() )
		{
			return nullptr;
		}
		const int32 Before = World->GetCurrentLevel()->Actors.Num();
		const FBox Everything( FVector( -HALF_WORLD_MAX ), FVector( HALF_WORLD_MAX ) );
		TUniquePtr<FLoaderAdapterShape> Loader = MakeUnique<FLoaderAdapterShape>( World, Everything, TEXT( "GodotFab" ) );
		Loader->Load();
		UE_LOG( LogTemp, Display, TEXT( "GodotFab: World Partition map, loaded %d actors (%d before)" ),
			World->GetCurrentLevel()->Actors.Num(), Before );
		return Loader;
	}
}

int32 UUnrealToGodotCommandlet::Main( const FString& Params )
{
	FString ContentPath;
	FString MapPath;
	FString Output;
	// A comma separated list: packs can install several top-level folders.
	FParse::Value( *Params, TEXT( "ContentPath=" ), ContentPath, false );
	FParse::Value( *Params, TEXT( "Map=" ), MapPath );
	FParse::Value( *Params, TEXT( "Output=" ), Output );
	const bool bSkinnedAsStatic = FParse::Param( *Params, TEXT( "SkinnedAsStatic" ) );
	const bool bNaniteOriginal = FParse::Param( *Params, TEXT( "NaniteOriginal" ) );
	const bool bNoTextures = FParse::Param( *Params, TEXT( "NoTextures" ) );
	const bool bNoPhysics = FParse::Param( *Params, TEXT( "NoPhysics" ) );
	const bool bNoLandscapes = FParse::Param( *Params, TEXT( "NoLandscapes" ) );

	ContentPath.TrimStartAndEndInline();
	ContentPath.TrimQuotesInline();
	TArray<FString> ContentPaths;
	{
		TArray<FString> Parts;
		ContentPath.ParseIntoArray( Parts, TEXT( "," ), true );
		for( FString& Part : Parts )
		{
			Part.TrimStartAndEndInline();
			while( Part.Len() > 1 && Part.EndsWith( TEXT( "/" ) ) )
			{
				Part.LeftChopInline( 1 );
			}
			if( !Part.IsEmpty() )
			{
				ContentPaths.Add( Part );
			}
		}
		ContentPath = FString::Join( ContentPaths, TEXT( "," ) );
	}
	MapPath.TrimStartAndEndInline();
	MapPath.TrimQuotesInline();
	Output.TrimStartAndEndInline();
	Output.TrimQuotesInline();
	Output.ReplaceInline( TEXT( "\\" ), TEXT( "/" ) );

	if( Output.IsEmpty() )
	{
		return Fail( TEXT( "-Output=<directory> is required" ) );
	}
	if( !Output.EndsWith( TEXT( "/" ) ) )
	{
		Output += TEXT( "/" );
	}
	if( MapPath.IsEmpty() && ContentPath.IsEmpty() )
	{
		return Fail( TEXT( "either -Map=<package path> or -ContentPath=<package path> is required" ) );
	}
	if( !IFileManager::Get().MakeDirectory( *Output, true ) )
	{
		return Fail( FString::Printf( TEXT( "could not create output directory %s" ), *Output ) );
	}
	if( !GEditor )
	{
		return Fail( TEXT( "GEditor is not available (the commandlet must run with an editor build)" ) );
	}

	UE_LOG( LogTemp, Display, TEXT( "GodotFab: output=%s map=%s content=%s skinnedAsStatic=%d naniteOriginal=%d textures=%d physics=%d" ),
		*Output, *MapPath, *ContentPath, bSkinnedAsStatic ? 1 : 0, bNaniteOriginal ? 1 : 0, bNoTextures ? 0 : 1, bNoPhysics ? 0 : 1 );

	UWorld* World = nullptr;
	TUniquePtr<FLoaderAdapterShape> WorldPartitionLoader;
	if( !MapPath.IsEmpty() )
	{
		UE_LOG( LogTemp, Display, TEXT( "GodotFab: loading map %s" ), *MapPath );
		if( !FEditorFileUtils::LoadMap( MapPath, false, false ) )
		{
			return Fail( FString::Printf( TEXT( "could not load map %s" ), *MapPath ) );
		}
		World = GEditor->GetEditorWorldContext().World();
		if( !World )
		{
			return Fail( TEXT( "no editor world after loading the map" ) );
		}
		UE_LOG( LogTemp, Display, TEXT( "GodotFab: loaded %s (world %s)" ), *World->GetOutermost()->GetName(), *World->GetName() );
		WorldPartitionLoader = LoadWorldPartitionActors( World );
		if( !ContentPaths.IsEmpty() && !FParse::Param( *Params, TEXT( "MapOnly" ) ) )
		{
			AddUnplacedPackMeshes( World, ContentPaths );
		}
	}
	else
	{
		World = GEditor->NewMap();
		if( !World )
		{
			return Fail( TEXT( "could not create a new map" ) );
		}

		// Name the scene after the last folder of the content path so the .tscn is recognisable.
		FString SceneName = FPaths::GetCleanFilename( ContentPaths[ 0 ] );
		if( !SceneName.IsEmpty() && SceneName != World->GetName() )
		{
			World->Rename( *SceneName, nullptr, REN_NonTransactional | REN_DontCreateRedirectors );
		}

		const int32 Spawned = SpawnMeshesFromContentPath( World, ContentPaths );
		if( Spawned <= 0 )
		{
			return Fail( FString::Printf( TEXT( "no StaticMesh/SkeletalMesh assets found under %s" ), *ContentPath ) );
		}
		UE_LOG( LogTemp, Display, TEXT( "GodotFab: spawned %d mesh actors in world %s" ), Spawned, *World->GetName() );
	}

	InstantiateExporter( EngineType::GODOT );
	if( !ExporterInterface )
	{
		return Fail( TEXT( "could not instantiate the Godot exporter" ) );
	}
	EnsureSettingsExists();

	UBaseSettingsClass* Settings = ExporterInterface->Settings;
	Settings->OutputDirectory = Output;
	Settings->SkinnedMeshes = bSkinnedAsStatic ? SkinnedMeshOptionsEnum::SMO_EXPORT_AS_STATIC : SkinnedMeshOptionsEnum::SMO_EXPORT_AS_SKINNED;
	Settings->NaniteOptions = bNaniteOriginal ? NaniteOptionsEnum::NANITE_ORIGINAL_MESH : NaniteOptionsEnum::NANITE_COARSE_MESH;
	Settings->ExportTextures = !bNoTextures;
	Settings->ExportPhysics = !bNoPhysics;
	if( UGodotSettingsClass* GodotSettings = Cast<UGodotSettingsClass>( Settings ) )
	{
		GodotSettings->GenerateProjectFiles = true;
	}

	const FString WorldName = World->GetName();
	UE_LOG( LogTemp, Display, TEXT( "GodotFab: exporting world %s to %s" ), *WorldName, *Output );

	// Same sequence as the plugin's DoExport, except that the actor rotation is done here
	// with a commandlet-safe helper (see RotateActorsForExport above).
	DoRotateOnExport = false;
	// The plugin exports landscapes only after its "ConvertLandscapesToStaticMeshes" menu
	// action (commented out of DoPrepareForExport): run it. It edits the landscape
	// materials in memory only (autosave off; a commandlet never saves packages).
	if( !bNoLandscapes )
	{
		int32 Proxies = 0;
		for( TActorIterator<ALandscapeProxy> It( World ); It; ++It )
			Proxies++;
		if( Proxies > 0 )
		{
			UE_LOG( LogTemp, Display, TEXT( "GodotFab: converting %d landscape proxies to static meshes" ), Proxies );
			FModuleManager::LoadModuleChecked<FUnrealToXModule>( TEXT( "UnrealToGodot" ) ).ConvertLandscapesToStaticMeshes();
		}
	}
	FUnrealToXModule::DoPrepareForExport();
	AExportActor::DetachAllActors();
	RotateActorsForExport( World, true );
	FUnrealToXModule::DoExport();
	RotateActorsForExport( World, false );

	// Verify what the exporter produced.
	const FString ProjectFile = Output + TEXT( "project.godot" );
	if( !FPaths::FileExists( ProjectFile ) )
	{
		return Fail( FString::Printf( TEXT( "exporter did not write %s" ), *ProjectFile ) );
	}

	TArray<FString> SceneFiles;
	IFileManager::Get().FindFilesRecursive( SceneFiles, *Output, TEXT( "*.tscn" ), true, false );
	FString MainScene;
	for( const FString& SceneFile : SceneFiles )
	{
		if( FPaths::GetBaseFilename( SceneFile ) == WorldName )
		{
			MainScene = SceneFile;
			break;
		}
	}
	if( MainScene.IsEmpty() )
	{
		return Fail( FString::Printf( TEXT( "exporter did not write %s.tscn under %s (%d scene files found)" ), *WorldName, *Output, SceneFiles.Num() ) );
	}
	FPaths::MakePathRelativeTo( MainScene, *Output );

	if( FPaths::FileExists( Output + TEXT( "WorldEnvironment.tscn" ) ) )
		WriteGodotEnvironment( World, Output );

	WriteNearestTextures( Output );
	WriteOpacityTextures( Output );

	FString Done = FString::Printf( TEXT( "scene=%s\nworld=%s\nmap=%s\ncontent=%s\n" ), *MainScene, *WorldName, *MapPath, *ContentPath );
	if( !FFileHelper::SaveStringToFile( Done, *( Output + TEXT( "godotfab_done.txt" ) ) ) )
	{
		return Fail( TEXT( "could not write godotfab_done.txt" ) );
	}

	UE_LOG( LogTemp, Display, TEXT( "GodotFab: scene %s" ), *MainScene );
	UE_LOG( LogTemp, Display, TEXT( "GodotFab: export finished" ) );
	return 0;
}
