<p align="center">
  <img src="logo.png" alt="PocketMap" width="320">
</p>

<h1 align="center">PocketMap</h1>

<p align="center">
  Shrink any Garry's Mod map into a glass block, then step inside and walk around in it.
</p>

---

## What is this?

PocketMap adds one entity, a glass block called **Pocket Map**. Pick an installed map and it is rebuilt at runtime as a tiny version of itself inside the block. Then walk into it. Everyone near the block sees a tiny version of you running through the map.

It is also a proof of concept for what [NikNaks](https://github.com/Nak2/NikNaks) can read out of a `.bsp`: everything you see is rebuilt at runtime from the map file, with no pre-made models and no map-specific code.

> [!WARNING]
> This is a proof of concept and **will have bugs**. No entity logic is parsed, so doors, buttons, triggers and lights don't work. You can walk around in the map, but the map itself is static. Dynamic prop entities and moving brushes are not solid.

## Features

- **Walk inside the map:** press <kbd>R</kbd> on a block to teleport in, and <kbd>R</kbd> again to leave. WASD, jump, run, crouch and ladders, with your noclip key for flying around.
- **Mini you:** players near the block see your player model, animated, walking around inside it.
- **Real collision:** brushes, terrain, water and static props are solid, and ladders can be climbed.
- **Footsteps:** the sound follows the surface you walk on: concrete, wood, metal, water, ladders and more.
- **Any map you have installed:** pick one from a browsable map list, and swap it at any time.

## How to use it

Spawn the **Pocket Map** block from the **Entities** tab of the spawn menu, under **Fun + Games**. Press <kbd>E</kbd> on it to pick a map. Once it has loaded, aim at the block and press <kbd>R</kbd> (your reload key) to walk in.

## Walking in a map

You start at a random player spawn of the map. Your noclip key (default V) or `pocketmap_noclip` toggles flight, and flying out of the block ends the walk. Your camera moves through the map and your real player stays in the main world.

- **Collision:** brushes, displacements, ladders, water and static props (from their `.phy` files).
- **Footsteps:** the sound comes from the surface you stand on, including props, water and ladders.
- **Movement:** it reads the server's movement ConVars, such as `sv_airaccelerate`, and runs the gamemode's `SetupMove`, `Move` and `FinishMove` hooks, including Sandbox's jump boost. Server-only behavior and callbacks that change real entities are not compatible.
- **Other players:** your position, angles and velocity are sent to the server, which checks that they are inside the block and relays them to players near it. They see your player model, which the client never sends: it is read from the server's own player data, with `models/kleiner.mdl` as the fallback.

## Multiplayer and servers

- The map and walking are simulated on your own client.
- The server is not required to have the given map.
- Changing a block's map and sending positions are rate limited.
- Set `pocketmap_adminonly 1` on a public server so only admins can change the map of a block.

## Requirements

- [NikNaks](https://github.com/Nak2/NikNaks) 0.975 or newer
- The map installed on every client that should see it (others see a red hologram)

## What gets rendered

World geometry (faces, brush entities, displacements), baked lighting with animated and switchable light styles, static props and entity models lit the way the engine lights them, grass and plants, the skybox and 3D skybox, and optionally the reflection and refraction of water.

## What data can you get from a map?

| What | NikNaks |
| --- | --- |
| The map | `NikNaks.Map( name )` |
| Faces, planes, vertices, brush models | `bsp:GetFaces()`, `GetPlanes()`, `GetVertex()`, `GetBModels()` |
| Texture, world or brush entity, tool textures | `face:GetTexture()`, `IsWorld()`, `ShouldRender()`, `GetEntity()` |
| Displacements (terrain) | `bsp:GetDispInfo()`, `GetDispVerts()` |
| Drawable meshes | `NikNaks.MeshBuilder()` |
| Baked lighting and light styles | `bsp:CreateLightmapAtlas()` |
| Every entity as key-values | `bsp:GetEntities()` |
| Static props | `bsp:GetStaticProps()` |
| Collision of a prop model | `NikNaks.Physics.Load( model )` |
| Grass and plants | `bsp:GetDetailPropInfo()`, `GetDetailProp()` |
| Ambient light of a spot, sun | `leaf:CalculateAmbientCube()`, `bsp:GetWorldLights()` |
| 3D skybox | `bsp:GetSkyBoxPos()`, `GetSkyBoxScale()`, `GetSkyboxLeafs()` |
| Open space of the map | `bsp:GetLeafs()`, `PointInLeaf()` |
| Rays against the map | `bsp:SurfaceTraceLine()` |

## Settings

| ConVar | Default | |
| --- | --- | --- |
| `pocketmap_propmeshes` | `1` | Bake models into the map instead of one `ClientsideModel` per prop |
| `pocketmap_lighttoggle` | `1` | Include switchable and animated light styles |
| `pocketmap_water` | `0` | Water reflects the tiny map (costly) |
| `pocketmap_maxmaps` | `5` | Most maps loaded at once (each uses up to 64 MB of video memory) |
| `pocketmap_adminonly` | `0` | Server: only admins can change a block's map |

Console commands: `pocketmap_walk` and `pocketmap_noclip`.

## For developers

Each file in `lua/pocketmap` is one topic, so the code doubles as an example of using NikNaks. Start with `cl_loader.lua`, which lists the stages that turn a `.bsp` into meshes. Other addons can refuse a map change with the `PocketMap_CanSelect` hook and a walk with `PocketMap_CanWalk` (both server side, return `false`).

## License

[CC0 1.0](LICENSE): use the code however you like, in any project, with no credit or notice required. If you find it useful and we meet some day, you can buy me a beer, but that's not required. (`cl_maplist.lua` is based on Facepunch's MIT-licensed `getmaplist.lua` and keeps its own notice.)
