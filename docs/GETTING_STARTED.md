# Getting started

*English | [Português](GETTING_STARTED-PTBR.md)* · [Back to the README](../README.md)

This guide takes you from an empty Godot project to a Fab asset in your scene, using the
glTF or FBX formats, which work on every platform (Linux, Windows and macOS).

> **Unreal Engine assets are Linux only for now.** Converting `.uasset` packages needs Unreal
> Engine 5.8 and a plugin built on Linux; see [the README](../README.md#unrealtogodot-commandlet-unreal-path-only) if you want
> to set it up. Everything below works without Unreal.

## 1. Install the addon

1. On the [repository page](https://github.com/alextrevisan/GodotFab), click *Code → Download ZIP*
   and extract it anywhere.
2. Copy its `addons/godotfab` folder into your Godot 4.8 project. You should end up with
   `res://addons/godotfab/plugin.cfg`.
3. In Godot, open *Project → Project Settings → Plugins* and enable **GodotFab**.

A **Fab** tab appears in the editor's top bar, next to 2D, 3D and Script.

## 2. Log in to Epic Games

Downloads come from your Fab library, so you need an Epic Games account.

1. In the **Fab** tab, open the menu (the icon to the right of the search box) and choose
   **Log In to Epic Games…**.
2. Click **Open login page in browser** and log in on the Epic page.
3. The page shows a JSON text with an `authorizationCode`. Copy only the code and paste it into
   the dialog, then click **Log In**.

The login is saved; you only need to do this again if it expires.

## 3. Find an asset

1. Type in **Search Fab assets** and press Enter. Use **Free only** to see only free assets.
2. Click a thumbnail to open its details: description, formats and price.

Searching works without logging in. Only assets that offer glTF, FBX or Unreal Engine formats are
listed.

## 4. Add it to your library

Fab only lets you download assets that are in your library.

- **Free asset:** click **Add on fab.com**. The asset page opens in the browser; click
  *Add to My Library* there, then come back to Godot and click **Refresh library**.
- **Paid asset:** click **Buy on fab.com** and buy it on the website.

If you already clicked **Download**, it waits and continues on its own once the asset shows up
in your library.

## 5. Download

1. In the asset details, click **Download**. By default the addon picks glTF, then FBX
   (*Settings → Preferred format*).
2. The progress shows in the dialog. Downloads that stop halfway continue where they stopped.
3. When it finishes, the asset is in `res://fab_assets/<asset name>/`.

## 6. Use it in a scene

- Click **Open Scene** in the asset details, or open the `.glb` / `.fbx` file from the
  FileSystem dock.
- To place it in your level, drag the `.glb` / `.fbx` file from the FileSystem dock into the 3D
  viewport.
- To edit the imported model, right-click it in the scene and choose *Make Local*, or use
  *Scene → New Inherited Scene*.

## Next steps

- Settings such as the download folder are under the menu → **Settings…**.
- Download problems (HTTP 403, Fab terms, error 429) are explained in
  [Troubleshooting](../README.md#troubleshooting).
