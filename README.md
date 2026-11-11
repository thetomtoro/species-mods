# Species: Unknown mods

A small mod pack for private Species: Unknown games with friends, plus a launcher that keeps it up to date.

## Install (once)

1. Own Species: Unknown on Steam and run it at least once.
2. Download [Install-Species-Mods.bat](https://github.com/thetomtoro/species-mods/releases/latest/download/Install-Species-Mods.bat).
3. Double-click it. Windows may say "Windows protected your PC" because the file is not signed: click **More info**, then **Run anyway**.
4. When it says setup finished, you have two new desktop shortcuts.

## Play

- **Species Unknown (Modded)** checks for a newer pack, updates if needed, then starts the game through Steam. If you are already current it takes about a second.
- **Species Unknown (No Mods)** turns the mods off and starts the game normally.

You never need to reinstall. New versions arrive the next time you use the Modded shortcut.

## Good to know

- The game's developer blocks public lobbies while mods are installed. Use private lobbies with the Modded shortcut, and the No Mods shortcut for public games.
- If the game gets a Steam update, the launcher turns the mods off until the pack has been checked against the new version, so a game patch cannot crash you.
- If you are offline, the game starts with the mods you already have.
- Starting the game straight from Steam keeps whatever state the last shortcut left (mods on or off).

## What it installs

- The launcher: `%LOCALAPPDATA%\SpeciesMods`
- In the game folder (`SpeciesUnknown\Binaries\Win64`): `dwmapi.dll` and a `ue4ss` folder. This is [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), an open-source script loader (MIT license), plus the mods in `ue4ss\Mods`.

It does not change the game's own files or your saves.

## Remove

Run `Uninstall Species Mods.bat` in `%LOCALAPPDATA%\SpeciesMods`. It removes the mods, the loader and the shortcuts.

## Mods in the pack

- **Encounter Variety**: turns the game's weighted monster pick into an even, shuffled rotation, so you see every eligible species before any repeats. Only the host's copy has any effect.
