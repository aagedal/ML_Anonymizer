/*
** Multi-Layer Anonymizer - host-independent algorithm core.
**
** Shared by the Premiere Pro plugin (src/) and the OpenFX plugin for
** DaVinci Resolve (ofx/). Everything here operates on tightly packed
** 4-channel float buffers (row pitch == width) and is channel-order
** agnostic except where noted.
**
** The same noise / sampling code exists in MSL in AnonymizerKernel.h -
** keep the two in sync so CPU and GPU renders are interchangeable.
*/

#ifndef ANONYMIZER_ALGO_H
#define ANONYMIZER_ALGO_H

#include <math.h>
#include <stdint.h>
#include <string.h>
#include <vector>
#include <algorithm>

/*
** Parameter ranges and defaults, shared by both host UIs.
*/
#define DISTORT_AMOUNT_MIN   0.0
#define DISTORT_AMOUNT_MAX   200.0
#define DISTORT_AMOUNT_DFLT  10.0

#define DISTORT_SCALE_MIN    4.0
#define DISTORT_SCALE_MAX    400.0
#define DISTORT_SCALE_DFLT   4.0

#define BLUR_RADIUS_MIN      0.0
#define BLUR_RADIUS_MAX      100.0
#define BLUR_RADIUS_DFLT     10.0

#define MOSAIC_SIZE_MIN      1.0
#define MOSAIC_SIZE_MAX      256.0
#define MOSAIC_SIZE_DFLT     25.0

#define SEED_MIN             0.0
#define SEED_MAX             10000.0
#define SEED_DFLT            0.0

/*
** Deterministic hash / seed helpers.
*/
static inline uint32_t AnonIHash(uint32_t x)
{
	x ^= x >> 16;
	x *= 0x7feb352dU;
	x ^= x >> 15;
	x *= 0x846ca68bU;
	x ^= x >> 16;
	return x;
}

static inline uint32_t AnonComputeSeed(double inSeedParam, bool inJitter, int32_t inFrame)
{
	uint32_t s = (uint32_t)(inSeedParam + 0.5);
	uint32_t f = inJitter ? (uint32_t)inFrame : 0u;
	return AnonIHash(s * 0x9E3779B1u ^ f * 0x85EBCA77u ^ 0x5BD1E995u);
}

namespace AnonAlgo
{

inline float Rand01(int32_t ix, int32_t iy, uint32_t seed, uint32_t channel)
{
	uint32_t h = AnonIHash((uint32_t)ix * 0x9E3779B1u
		^ (uint32_t)iy * 0x85EBCA77u
		^ seed * 0xC2B2AE3Du
		^ channel * 0x27D4EB2Fu);
	return (float)h * (1.0f / 4294967295.0f);
}

inline float SmoothT(float t)
{
	return t * t * (3.0f - 2.0f * t);
}

// Smoothly interpolated per-cell value noise in [0,1]
inline float VNoise(float px, float py, uint32_t seed, uint32_t channel)
{
	float fx = floorf(px);
	float fy = floorf(py);
	int32_t ix = (int32_t)fx;
	int32_t iy = (int32_t)fy;
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

inline const float* PixAt(const float* buf, int w, int x, int y)
{
	return buf + ((size_t)y * w + x) * 4;
}

inline void SampleBilinear(const float* buf, int w, int h, float x, float y, float* outPix)
{
	x = std::min(std::max(x, 0.0f), (float)(w - 1));
	y = std::min(std::max(y, 0.0f), (float)(h - 1));
	int x0 = (int)floorf(x);
	int y0 = (int)floorf(y);
	int x1 = std::min(x0 + 1, w - 1);
	int y1 = std::min(y0 + 1, h - 1);
	float tx = x - (float)x0;
	float ty = y - (float)y0;
	const float* p00 = PixAt(buf, w, x0, y0);
	const float* p10 = PixAt(buf, w, x1, y0);
	const float* p01 = PixAt(buf, w, x0, y1);
	const float* p11 = PixAt(buf, w, x1, y1);
	for (int c = 0; c < 4; ++c)
	{
		float top = p00[c] + (p10[c] - p00[c]) * tx;
		float bot = p01[c] + (p11[c] - p01[c]) * tx;
		outPix[c] = top + (bot - top) * ty;
	}
}

inline void DistortPass(const float* src, float* dst, int w, int h,
	float amount, float scale, uint32_t seed)
{
	if (amount <= 0.001f)
	{
		memcpy(dst, src, (size_t)w * h * 4 * sizeof(float));
		return;
	}
	float invScale = 1.0f / std::max(scale, 2.0f);
	for (int y = 0; y < h; ++y)
	{
		float* out = dst + (size_t)y * w * 4;
		for (int x = 0; x < w; ++x, out += 4)
		{
			float nx = VNoise((float)x * invScale, (float)y * invScale, seed, 0u);
			float ny = VNoise((float)x * invScale, (float)y * invScale, seed, 1u);
			float dx = (nx * 2.0f - 1.0f) * amount;
			float dy = (ny * 2.0f - 1.0f) * amount;
			SampleBilinear(src, w, h, (float)x + dx, (float)y + dy, out);
		}
	}
}

// dir 0 = horizontal, 1 = vertical
inline void BlurPass(const float* src, float* dst, int w, int h, float radius, int dir)
{
	int r = (int)ceilf(radius);
	if (r < 1)
	{
		memcpy(dst, src, (size_t)w * h * 4 * sizeof(float));
		return;
	}
	float sigma = std::max(radius * 0.5f, 0.1f);
	std::vector<float> weights(2 * r + 1);
	for (int i = -r; i <= r; ++i)
		weights[i + r] = expf(-(float)(i * i) / (2.0f * sigma * sigma));

	for (int y = 0; y < h; ++y)
	{
		float* out = dst + (size_t)y * w * 4;
		for (int x = 0; x < w; ++x, out += 4)
		{
			float acc[4] = {0, 0, 0, 0};
			float sum = 0.0f;
			for (int i = -r; i <= r; ++i)
			{
				int sx = dir == 0 ? std::min(std::max(x + i, 0), w - 1) : x;
				int sy = dir == 1 ? std::min(std::max(y + i, 0), h - 1) : y;
				const float* p = PixAt(src, w, sx, sy);
				float wgt = weights[i + r];
				acc[0] += p[0] * wgt;
				acc[1] += p[1] * wgt;
				acc[2] += p[2] * wgt;
				acc[3] += p[3] * wgt;
				sum += wgt;
			}
			float inv = 1.0f / sum;
			out[0] = acc[0] * inv;
			out[1] = acc[1] * inv;
			out[2] = acc[2] * inv;
			out[3] = acc[3] * inv;
		}
	}
}

inline void MosaicPass(const float* src, float* dst, int w, int h, float blockSize)
{
	int b = std::max(1, (int)(blockSize + 0.5f));
	if (b <= 1)
	{
		memcpy(dst, src, (size_t)w * h * 4 * sizeof(float));
		return;
	}
	for (int y = 0; y < h; ++y)
	{
		float* out = dst + (size_t)y * w * 4;
		int sy = std::min((y / b) * b + b / 2, h - 1);
		for (int x = 0; x < w; ++x, out += 4)
		{
			int sx = std::min((x / b) * b + b / 2, w - 1);
			const float* p = PixAt(src, w, sx, sy);
			out[0] = p[0];
			out[1] = p[1];
			out[2] = p[2];
			out[3] = p[3];
		}
	}
}

// Runs the full stack in place on a packed float buffer (any channel order),
// using the caller's scratch buffer of the same size. Result lands in `buf`.
inline void RunLayeredPasses(float* buf, float* scratch, int w, int h,
	float amount, float scale, float blurRadius, float mosaicSize, uint32_t seed)
{
	DistortPass(buf, scratch, w, h, amount, scale, seed);
	BlurPass(scratch, buf, w, h, blurRadius, 0);
	BlurPass(buf, scratch, w, h, blurRadius, 1);
	MosaicPass(scratch, buf, w, h, mosaicSize);
}

} // namespace AnonAlgo

#endif // ANONYMIZER_ALGO_H
