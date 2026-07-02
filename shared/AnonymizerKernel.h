/*
** Multi-Layer Anonymizer - Metal compute kernels.
**
** The MSL source is embedded as a string and compiled at runtime with
** newLibraryWithSource (same approach as Adobe's SDK_ProcAmp GPU sample).
**
** The noise / sampling functions mirror the CPU implementations in
** Anonymizer_CPU.cpp - keep the two in sync so software and GPU renders
** are interchangeable.
**
** Frames are BGRA buffers, float4 (32f) or half4 (16f) per pixel, selected
** by params.is16f at runtime.
*/

#ifndef ANONYMIZER_KERNEL_H
#define ANONYMIZER_KERNEL_H

static const char* const kAnonymizerMetalString = R"MSLSRC(
#include <metal_stdlib>
using namespace metal;

struct AnonParams
{
	int srcPitch;
	int dstPitch;
	int is16f;
	int width;
	int height;
	int blurRadius;
	int blurDir;
	float distortAmount;
	float distortScale;
	float blurSigma;
	float mosaicSize;
	uint seed;
};

inline float4 LoadPix(device const uchar* buf, int pitch, int x, int y, int is16f)
{
	int idx = y * pitch + x;
	if (is16f)
		return float4(((device const half4*)buf)[idx]);
	return ((device const float4*)buf)[idx];
}

inline void StorePix(device uchar* buf, int pitch, int x, int y, int is16f, float4 v)
{
	int idx = y * pitch + x;
	if (is16f)
		((device half4*)buf)[idx] = half4(v);
	else
		((device float4*)buf)[idx] = v;
}

inline float4 SampleBilinear(device const uchar* buf, int pitch, int w, int h, int is16f, float2 p)
{
	float x = clamp(p.x, 0.0f, float(w - 1));
	float y = clamp(p.y, 0.0f, float(h - 1));
	int x0 = int(floor(x));
	int y0 = int(floor(y));
	int x1 = min(x0 + 1, w - 1);
	int y1 = min(y0 + 1, h - 1);
	float tx = x - float(x0);
	float ty = y - float(y0);
	float4 p00 = LoadPix(buf, pitch, x0, y0, is16f);
	float4 p10 = LoadPix(buf, pitch, x1, y0, is16f);
	float4 p01 = LoadPix(buf, pitch, x0, y1, is16f);
	float4 p11 = LoadPix(buf, pitch, x1, y1, is16f);
	float4 top = p00 + (p10 - p00) * tx;
	float4 bot = p01 + (p11 - p01) * tx;
	return top + (bot - top) * ty;
}

// ---- Deterministic noise, mirrored from Anonymizer.h / Anonymizer_CPU.cpp ----

inline uint IHash(uint x)
{
	x ^= x >> 16;
	x *= 0x7feb352dU;
	x ^= x >> 15;
	x *= 0x846ca68bU;
	x ^= x >> 16;
	return x;
}

inline float Rand01(int ix, int iy, uint seed, uint channel)
{
	uint h = IHash(uint(ix) * 0x9E3779B1u
		^ uint(iy) * 0x85EBCA77u
		^ seed * 0xC2B2AE3Du
		^ channel * 0x27D4EB2Fu);
	return float(h) * (1.0f / 4294967295.0f);
}

inline float SmoothT(float t)
{
	return t * t * (3.0f - 2.0f * t);
}

inline float VNoise(float px, float py, uint seed, uint channel)
{
	float fx = floor(px);
	float fy = floor(py);
	int ix = int(fx);
	int iy = int(fy);
	float tx = SmoothT(px - fx);
	float ty = SmoothT(py - fy);
	float a = Rand01(ix,     iy,     seed, channel);
	float b = Rand01(ix + 1, iy,     seed, channel);
	float c = Rand01(ix,     iy + 1, seed, channel);
	float d = Rand01(ix + 1, iy + 1, seed, channel);
	float ab = a + (b - a) * tx;
	float cd = c + (d - c) * tx;
	return ab + (cd - ab) * ty;
}

// ---- Layer 1: random spatial distortion ----

kernel void AnonDistort(
	device const uchar* src [[buffer(0)]],
	device uchar* dst [[buffer(1)]],
	constant AnonParams& p [[buffer(2)]],
	uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= uint(p.width) || gid.y >= uint(p.height))
		return;
	int x = int(gid.x);
	int y = int(gid.y);
	float4 c;
	if (p.distortAmount <= 0.001f)
	{
		c = LoadPix(src, p.srcPitch, x, y, p.is16f);
	}
	else
	{
		float invScale = 1.0f / max(p.distortScale, 2.0f);
		float nx = VNoise(float(x) * invScale, float(y) * invScale, p.seed, 0u);
		float ny = VNoise(float(x) * invScale, float(y) * invScale, p.seed, 1u);
		float dx = (nx * 2.0f - 1.0f) * p.distortAmount;
		float dy = (ny * 2.0f - 1.0f) * p.distortAmount;
		c = SampleBilinear(src, p.srcPitch, p.width, p.height, p.is16f,
			float2(float(x) + dx, float(y) + dy));
	}
	StorePix(dst, p.dstPitch, x, y, p.is16f, c);
}

// ---- Layer 2: separable Gaussian blur (blurDir 0 = H, 1 = V) ----

kernel void AnonBlur(
	device const uchar* src [[buffer(0)]],
	device uchar* dst [[buffer(1)]],
	constant AnonParams& p [[buffer(2)]],
	uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= uint(p.width) || gid.y >= uint(p.height))
		return;
	int x = int(gid.x);
	int y = int(gid.y);
	int r = p.blurRadius;
	if (r < 1)
	{
		StorePix(dst, p.dstPitch, x, y, p.is16f, LoadPix(src, p.srcPitch, x, y, p.is16f));
		return;
	}
	float twoSigmaSq = 2.0f * p.blurSigma * p.blurSigma;
	float4 acc = float4(0.0f);
	float sum = 0.0f;
	for (int i = -r; i <= r; ++i)
	{
		int sx = p.blurDir == 0 ? clamp(x + i, 0, p.width - 1) : x;
		int sy = p.blurDir == 1 ? clamp(y + i, 0, p.height - 1) : y;
		float wgt = exp(-float(i * i) / twoSigmaSq);
		acc += LoadPix(src, p.srcPitch, sx, sy, p.is16f) * wgt;
		sum += wgt;
	}
	StorePix(dst, p.dstPitch, x, y, p.is16f, acc / sum);
}

// ---- Blackout: solid black, source alpha preserved (BGRA -> w is alpha) ----

kernel void AnonBlackout(
	device const uchar* src [[buffer(0)]],
	device uchar* dst [[buffer(1)]],
	constant AnonParams& p [[buffer(2)]],
	uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= uint(p.width) || gid.y >= uint(p.height))
		return;
	int x = int(gid.x);
	int y = int(gid.y);
	float4 c = LoadPix(src, p.srcPitch, x, y, p.is16f);
	StorePix(dst, p.dstPitch, x, y, p.is16f, float4(0.0f, 0.0f, 0.0f, c.w));
}

// ---- Layer 3: mosaic ----

kernel void AnonMosaic(
	device const uchar* src [[buffer(0)]],
	device uchar* dst [[buffer(1)]],
	constant AnonParams& p [[buffer(2)]],
	uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= uint(p.width) || gid.y >= uint(p.height))
		return;
	int x = int(gid.x);
	int y = int(gid.y);
	int b = max(1, int(p.mosaicSize + 0.5f));
	int sx = min((x / b) * b + b / 2, p.width - 1);
	int sy = min((y / b) * b + b / 2, p.height - 1);
	StorePix(dst, p.dstPitch, x, y, p.is16f, LoadPix(src, p.srcPitch, sx, sy, p.is16f));
}
)MSLSRC";

#endif // ANONYMIZER_KERNEL_H
