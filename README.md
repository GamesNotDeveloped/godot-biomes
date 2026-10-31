# Godot Biomes

Procedural biomes for Godot 4: trees, plants and grass grown around the camera over a
[Terrain3D](https://github.com/TokisanGames/Terrain3D) terrain or any surface, in the editor and in
the game alike.

## Features

* `Biomes` node - models (`BiomeScatterEntry`: a mesh or a scene, with its probability and scale)
  scattered over an area, on a texture of its Terrain3D or by a painted mask
* `BiomesServer` (an autoload) grows them in chunks around the camera on worker threads, drawn as
  `RenderingServer` MultiMeshes - no nodes per instance
* LODs of a model: the model, a simplified mid model, a billboard; far billboards placed by the GPU
* density LOD, shadow meshes, chunk colliders
* `BiomesGrass` node - grass or grain as GPU particles following the camera, on the textures of its
  terrain
* far ground: past where a layer is drawn, its terrain's texture looks like the plants it carries
* far canopy: a forest's roof and edges baked with the world's far terrain (`BiomesFarCanopy`)
* the Biomes panel in the editor: painting masks, generating billboards, mid meshes, shadow meshes
  and the canopy texture
* follows the terrain painted in the editor: the chunks under a brush stroke are grown again

## Usage

* Enable the plugin: it adds the `BiomesServer` autoload
* Add a `Biomes` node to the 3D scene, set its `terrain` (a Terrain3D; without one the instances
  stand on what a physics ray finds) and its `terrain_texture` or a mask
* Add `BiomeScatterEntry` resources to its `entries`, each with a model
* Generate the billboards, mid meshes and shadow meshes in the Biomes panel
* For grass, add a `BiomesGrass` node with its terrain, its textures and a blade mesh

## Credits

`addons/gnd_biomes/grass/terrain_particles.gd` grew from Terrain3D's `extras/particle_example`,
Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors (MIT).
