/*
** Multi-Layer Anonymizer FxPlug - extra Metal functions.
**
** Appended to the shared kernel string (shared/AnonymizerKernel.h) at
** runtime. FxPlug hands us IOSurface-backed textures, so the pipeline is:
**
**   AnonCopyIn (texture -> float4 buffer)
**   ... shared buffer kernels (distort / blur / mosaic / blackout) ...
**   AnonVertex + AnonFragment (result buffer -> output texture via a
**   fullscreen quad; render pass avoids relying on ShaderWrite usage on the
**   host's output texture)
*/

#ifndef ANONYMIZER_FXPLUG_EXTRA_KERNELS_H
#define ANONYMIZER_FXPLUG_EXTRA_KERNELS_H

static const char* const kAnonymizerFxPlugExtraMetal = R"MSLEXTRA(

struct AnonCopyParams
{
	int width;
	int height;
};

kernel void AnonCopyIn(
	texture2d<float, access::read> src [[texture(0)]],
	device float4* dst [[buffer(0)]],
	constant AnonCopyParams& p [[buffer(1)]],
	uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= uint(p.width) || gid.y >= uint(p.height))
		return;
	dst[gid.y * p.width + gid.x] = src.read(gid);
}

struct AnonOutParams
{
	int width;        // full-frame width  (result buffer pitch)
	int height;       // full-frame height
	int tileOffsetX;  // dst tile origin within the full frame, texture rows
	int tileOffsetY;
};

struct AnonVarying
{
	float4 position [[position]];
};

vertex AnonVarying AnonVertex(uint vid [[vertex_id]])
{
	// Fullscreen triangle strip in clip space.
	float2 corners[4] = { {-1.0, -1.0}, {1.0, -1.0}, {-1.0, 1.0}, {1.0, 1.0} };
	AnonVarying out;
	out.position = float4(corners[vid], 0.0, 1.0);
	return out;
}

fragment float4 AnonFragment(
	AnonVarying in [[stage_in]],
	device const float4* result [[buffer(0)]],
	constant AnonOutParams& p [[buffer(1)]])
{
	int x = int(in.position.x) + p.tileOffsetX;
	int y = int(in.position.y) + p.tileOffsetY;
	x = clamp(x, 0, p.width - 1);
	y = clamp(y, 0, p.height - 1);
	return result[y * p.width + x];
}
)MSLEXTRA";

#endif // ANONYMIZER_FXPLUG_EXTRA_KERNELS_H
