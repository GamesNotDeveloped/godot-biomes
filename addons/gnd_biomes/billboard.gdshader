// the far LOD of a Biomes entry, a quad turning to the camera around Y.
// BaseMaterial3D's BILLBOARD_FIXED_Y lights the quad by its normal, which follows the camera: looking
// towards the sun a tree was lit from behind (grey-blue), looking away fully lit. Here the quad is
// lit as a crown seen from above (the normal points up), the same from every side.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

#include "billboard.gdshaderinc"
