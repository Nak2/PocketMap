<p align="center">
  <img src="logo.png" alt="PocketMap" width="320">
</p>

<h1 align="center">PocketMap</h1>

<p align="center">
  Shrink any Garry's Mod map into a glass block, then step inside and walk around in it.
</p>

---

## What is this?

PocketMap adds one entity, a block called **Pocket Map**. Pick a map and it is rebuilt at runtime as a tiny version inside itself. You can noclip or press R to enter the map as a clientside walkable player.

It is a proof of concept for what [NikNaks](https://github.com/Nak2/NikNaks) can parse out of a `.bsp`.

> [!WARNING]
> This **will have bugs**. No entity logic is parsed, so doors, buttons, triggers and lights don't work. You can walk around in the map, but the map itself is static. Dynamic prop entities and moving brushes are not solid.

## Features

- **Walk inside the map:** press <kbd>R</kbd> on the entity to teleport inside, and <kbd>R</kbd> again to leave. WASD, jump, run, crouch and ladders, with noclip key for flying around.
- **Mini you:** players near the block see your player model, animated, walking around inside it.
- **Real collision:** brushes, terrain, water and static props are solid, and ladders can be climbed.
- **Any map clients have installed:** pick one from a browsable map list. Server doesn't need to have the map installed.

## How to use it

Spawn the entity from the **Entities** tab of the spawn menu, under **Fun + Games**. Press <kbd>E</kbd> on it to pick a map. Once it has loaded, press <kbd>R</kbd> to walk in.

## Walking in a map

You start at a random player spawn of the map. Your noclip key (default V) or `pocketmap_noclip` toggles flight, and flying out of the block ends the walk. Your camera moves through the map and your real player stays in the main world.

- **Collision:** brushes, displacements, ladders, water and static props (from their `.phy` files).
- **Movement:** it reads the server's movement ConVars, such as `sv_airaccelerate`, and runs the gamemode's `SetupMove`, `Move` and `FinishMove` hooks, including Sandbox's jump boost. (Clientside)
- **Other players:** your position, angles and velocity are sent to the server, which relays them to players near it. They will see a tiny version of you within the map.

## Requirements

- [NikNaks](https://github.com/Nak2/NikNaks) 0.975 or newer

## NikNaks functions used

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

## License

[CC0 1.0](LICENSE): use the code however you like, in any project, with no credit or notice required. If you find it useful and we meet some day, you can buy me a beer, but that's not required. (`cl_maplist.lua` is based on Facepunch's MIT-licensed `getmaplist.lua` and keeps its own notice.)
