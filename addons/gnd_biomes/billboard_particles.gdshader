// The draw pass of a Biomes layer's billboards (billboards.gdshader): the billboard of a particle's
// entry (CUSTOM.x), turning to the camera around Y and lit as a crown seen from above, as
// billboard.gdshader draws the CPU's. A particle in a chunk nearer to view_position than its
// entry's lod_distance (the chunk's middle, horizontally - as BiomesServer shows the models there,
// _apply_near_visibility()) or farther than max_distance is folded away.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

#include "billboard_particles.gdshaderinc"
