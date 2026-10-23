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
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <vector>
#include <algorithm>

/*
** Parameter ranges and defaults, shared by both host UIs.
*/
#define DISTORT_AMOUNT_MIN   0.0
#define DISTORT_AMOUNT_MAX   200.0
#define DISTORT_AMOUNT_DFLT  15.0

#define DISTORT_SCALE_MIN    4.0
#define DISTORT_SCALE_MAX    400.0
#define DISTORT_SCALE_DFLT   10.0

#define BLUR_RADIUS_MIN      0.0
#define BLUR_RADIUS_MAX      100.0
#define BLUR_RADIUS_DFLT     15.0
#define BLUR_AFTER_MOSAIC_RADIUS_DFLT 35.0

#define MOSAIC_SIZE_MIN      1.0
#define MOSAIC_SIZE_MAX      256.0
#define MOSAIC_SIZE_DFLT     25.0

/* 2^24 - 1: the largest range a float slider (AE valid_max is a float)
** can step through exactly, and well inside every host's int range. */
#define SEED_MIN             0.0
#define SEED_MAX             16777215.0
#define SEED_DFLT            0.0

#define DESATURATE_MIN       0.0
#define DESATURATE_MAX       100.0
#define DESATURATE_DFLT      0.0

/*
** Pixel-space parameters are specified at a 1080p reference and scaled by
** the shorter frame dimension, so the anonymization strength is independent
** of both timeline resolution and orientation. Proxy/preview downsampling is
** handled automatically: a half-resolution frame has half the short dimension.
*/
#define ANON_REFERENCE_HEIGHT 1080.0f

/*
** Mosaic cell shapes (popup order in every host UI).
*/
enum
{
	ANON_SHAPE_SQUARE = 0,
	ANON_SHAPE_TRIANGLE = 1,
	ANON_SHAPE_HEXAGON = 2,
};

/*
** Channel layout of the 4-channel buffers, needed only by desaturation
** (every other pass treats the four channels identically).
*/
enum
{
	ANON_ORDER_RGBA = 0, // OFX, FxPlug, Photoshop
	ANON_ORDER_BGRA = 1, // Premiere Pro float / GPU frames
	ANON_ORDER_ARGB = 2, // After Effects 8-bit worlds
};

static inline float AnonResolutionScale(int inFrameWidth, int inFrameHeight)
{
	int shortSide = inFrameWidth < inFrameHeight ? inFrameWidth : inFrameHeight;
	if (shortSide <= 0)
		return 1.0f;
	return (float)shortSide / ANON_REFERENCE_HEIGHT;
}

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

static inline uint32_t AnonComputeSeed(double inSeedParam, bool inJitter, int32_t inFrame,
	uint32_t inSessionKey = 0u)
{
	uint32_t s = (uint32_t)(inSeedParam + 0.5);
	uint32_t f = inJitter ? (uint32_t)inFrame : 0u;
	uint32_t h = AnonIHash(s * 0x9E3779B1u ^ f * 0x85EBCA77u ^ 0x5BD1E995u);
	return inSessionKey ? AnonIHash(h ^ inSessionKey) : h;
}

namespace AnonAlgo
{

// Switch between the two blur defaults on user checkbox changes.
// Preserve other values; loading a project and rendering do not rewrite settings.
inline double BlurRadiusForOrderChange(double radius, bool blurAfterMosaic)
{
	if (blurAfterMosaic && radius == BLUR_RADIUS_DFLT)
		return BLUR_AFTER_MOSAIC_RADIUS_DFLT;
	if (!blurAfterMosaic && radius == BLUR_AFTER_MOSAIC_RADIUS_DFLT)
		return BLUR_RADIUS_DFLT;
	return radius;
}

/*
** Process-lifetime random key for the "Session Key" option. Drawn from the
** system CSPRNG on first use and never stored anywhere - not in the project,
** not on disk - so the exact distortion pattern cannot be reproduced even by
** someone holding the project file and seed. Non-static inline: one key per
** process, shared by the CPU and GPU translation units of a plugin.
*/
inline uint32_t SessionKey()
{
	static const uint32_t sKey = [] {
		uint32_t k = 0;
		while (k == 0) // 0 means "no key" to AnonComputeSeed
			k = arc4random();
		return k;
	}();
	return sKey;
}

/* Random value for the "Randomize Seed" buttons, within the seed range. */
inline int RandomSeedValue()
{
	return (int)arc4random_uniform((uint32_t)SEED_MAX) + 1;
}

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

/*
** Raw displacement field in [-1,1] per axis, before mean removal. Two
** octaves of value noise: the base octave at the user's scale, plus a
** finer octave (2.7x frequency, half weight) on a lattice rotated by
** atan(3/4) - an exact rotation (0.8 / 0.6) so CPU and GPU agree bit for
** bit. The rotated detail octave breaks up the axis-aligned, locally
** near-affine look of single-octave value noise, so small neighbourhoods
** are no longer just translated copies that a local-shift model could
** undo. Keep in sync with AnonDisplacement in AnonymizerKernel.h.
*/
inline void Displacement(float x, float y, float invScale, uint32_t seed,
	float* outDx, float* outDy)
{
	float px = x * invScale;
	float py = y * invScale;
	float qx = (px * 0.8f - py * 0.6f) * 2.7f;
	float qy = (px * 0.6f + py * 0.8f) * 2.7f;
	float n0 = VNoise(px, py, seed, 0u) * 2.0f - 1.0f;
	float n1 = VNoise(px, py, seed, 1u) * 2.0f - 1.0f;
	float n2 = VNoise(qx, qy, seed, 2u) * 2.0f - 1.0f;
	float n3 = VNoise(qx, qy, seed, 3u) * 2.0f - 1.0f;
	*outDx = (n0 + n2 * 0.5f) * 0.6666667f;
	*outDy = (n1 + n3 * 0.5f) * 0.6666667f;
}

/*
** Value noise has a non-zero spatial mean over any finite domain, causing
** a net DC translation of the whole image. The mean changes with each seed,
** so temporal jitter (different seed per frame) makes the whole image bounce.
** Fix: estimate the mean over a sparse uniform grid and subtract it so the
** net displacement is zero regardless of seed or frame size. Every host
** (CPU and GPU) uses this one function so the bias is identical.
*/
inline void DisplacementBias(int w, int h, float scale, uint32_t seed,
	float* outBiasDx, float* outBiasDy)
{
	float invScale = 1.0f / std::max(scale, 2.0f);
	const int kStep = std::max(1, std::max(w, h) / 64);
	float sumDx = 0.0f, sumDy = 0.0f;
	int count = 0;
	for (int sy = kStep / 2; sy < h; sy += kStep) {
		for (int sx = kStep / 2; sx < w; sx += kStep) {
			float dx, dy;
			Displacement((float)sx, (float)sy, invScale, seed, &dx, &dy);
			sumDx += dx;
			sumDy += dy;
			++count;
		}
	}
	*outBiasDx = count > 0 ? sumDx / (float)count : 0.0f;
	*outBiasDy = count > 0 ? sumDy / (float)count : 0.0f;
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
	float biasDx, biasDy;
	DisplacementBias(w, h, scale, seed, &biasDx, &biasDy);
	for (int y = 0; y < h; ++y)
	{
		float* out = dst + (size_t)y * w * 4;
		for (int x = 0; x < w; ++x, out += 4)
		{
			float nx, ny;
			Displacement((float)x, (float)y, invScale, seed, &nx, &ny);
			float dx = (nx - biasDx) * amount;
			float dy = (ny - biasDy) * amount;
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

// Rounds halfway cases up, matching the MSL implementation exactly.
inline float RoundHalfUp(float v)
{
	return floorf(v + 0.5f);
}

// Cell-center position for the triangle / hexagon tilings, in pixels.
// Keep in sync with the MSL version in AnonymizerKernel.h.
inline void MosaicCellCenter(float x, float y, float b, int shape, float* outX, float* outY)
{
	if (shape == ANON_SHAPE_TRIANGLE)
	{
		// Each b-sized square splits into two right triangles; the diagonal
		// direction alternates in a checkerboard for a woven look.
		float fx = x / b;
		float fy = y / b;
		float ixf = floorf(fx);
		float iyf = floorf(fy);
		float u = fx - ixf;
		float v = fy - iyf;
		float cx, cy;
		if (((int)(ixf + iyf) & 1) == 0)
		{
			if (u > v) { cx = 2.0f / 3.0f; cy = 1.0f / 3.0f; }
			else       { cx = 1.0f / 3.0f; cy = 2.0f / 3.0f; }
		}
		else
		{
			if (u + v < 1.0f) { cx = 1.0f / 3.0f; cy = 1.0f / 3.0f; }
			else              { cx = 2.0f / 3.0f; cy = 2.0f / 3.0f; }
		}
		*outX = (ixf + cx) * b;
		*outY = (iyf + cy) * b;
	}
	else // ANON_SHAPE_HEXAGON
	{
		// Pointy-top hexagonal grid via axial coordinates + cube rounding,
		// sized so a hexagon is roughly b pixels tall.
		float s = b * 0.5f;
		float qa = 0.57735027f * x;
		float qb = 0.33333333f * y;
		float qn = qa - qb;
		float qf = qn / s;
		float rn = 0.66666667f * y;
		float rf = rn / s;
		float xf = qf;
		float zf = rf;
		float yf = -xf - zf;
		float rx = RoundHalfUp(xf);
		float ry = RoundHalfUp(yf);
		float rz = RoundHalfUp(zf);
		float dx = fabsf(rx - xf);
		float dy = fabsf(ry - yf);
		float dz = fabsf(rz - zf);
		if (dx > dy && dx > dz)
			rx = -ry - rz;
		else if (dy > dz)
			ry = -rx - rz;
		else
			rz = -rx - ry;
		float hx = rz * 0.5f;
		float hy = rx + hx;
		float hz = s * 1.73205081f;
		float vy = s * 1.5f;
		*outX = hz * hy;
		*outY = vy * rz;
	}
}

inline void MosaicPass(const float* src, float* dst, int w, int h, float blockSize, int shape)
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
		int sqy = std::min((y / b) * b + b / 2, h - 1);
		for (int x = 0; x < w; ++x, out += 4)
		{
			int sx, sy;
			if (shape == ANON_SHAPE_SQUARE)
			{
				sx = std::min((x / b) * b + b / 2, w - 1);
				sy = sqy;
			}
			else
			{
				float cx, cy;
				MosaicCellCenter((float)x, (float)y, (float)b, shape, &cx, &cy);
				sx = std::min(std::max((int)RoundHalfUp(cx), 0), w - 1);
				sy = std::min(std::max((int)RoundHalfUp(cy), 0), h - 1);
			}
			const float* p = PixAt(src, w, sx, sy);
			out[0] = p[0];
			out[1] = p[1];
			out[2] = p[2];
			out[3] = p[3];
		}
	}
}

// Rec. 709 luma weights at the R, G, B positions of a channel order.
inline void LumaWeights(int channelOrder, float outW[4])
{
	const float r = 0.2126f, g = 0.7152f, b = 0.0722f;
	if (channelOrder == ANON_ORDER_BGRA)
		{ outW[0] = b; outW[1] = g; outW[2] = r; outW[3] = 0.0f; }
	else if (channelOrder == ANON_ORDER_ARGB)
		{ outW[0] = 0.0f; outW[1] = r; outW[2] = g; outW[3] = b; }
	else
		{ outW[0] = r; outW[1] = g; outW[2] = b; outW[3] = 0.0f; }
}

// Blends the colour channels toward luma by `amount` (0..1), alpha untouched.
// Every other pass is linear per channel, so desaturating last is identical
// to desaturating first. Keep in sync with AnonDesaturate in the MSL.
inline void DesaturatePass(float* buf, int w, int h, float amount, int channelOrder)
{
	if (amount <= 0.0f)
		return;
	amount = std::min(amount, 1.0f);
	float lw[4];
	LumaWeights(channelOrder, lw);
	const int alpha = channelOrder == ANON_ORDER_ARGB ? 0 : 3;
	for (size_t i = 0; i < (size_t)w * h; ++i)
	{
		float* p = buf + i * 4;
		float luma = p[0] * lw[0] + p[1] * lw[1] + p[2] * lw[2] + p[3] * lw[3];
		for (int c = 0; c < 4; ++c)
			if (c != alpha)
				p[c] = p[c] + (luma - p[c]) * amount;
	}
}

// Runs the full stack in place on a packed float buffer, using the caller's
// scratch buffer of the same size. Result lands in `buf`. desaturate is
// 0..1; channelOrder only matters when it is non-zero.
inline void RunLayeredPasses(float* buf, float* scratch, int w, int h,
	float amount, float scale, float blurRadius, float mosaicSize, int mosaicShape,
	uint32_t seed, bool blurAfterMosaic = false, float desaturate = 0.0f,
	int channelOrder = ANON_ORDER_RGBA)
{
	DistortPass(buf, scratch, w, h, amount, scale, seed);
	if (blurAfterMosaic)
	{
		MosaicPass(scratch, buf, w, h, mosaicSize, mosaicShape);
		BlurPass(buf, scratch, w, h, blurRadius, 0);
		BlurPass(scratch, buf, w, h, blurRadius, 1);
	}
	else
	{
		BlurPass(scratch, buf, w, h, blurRadius, 0);
		BlurPass(buf, scratch, w, h, blurRadius, 1);
		MosaicPass(scratch, buf, w, h, mosaicSize, mosaicShape);
	}
	DesaturatePass(buf, w, h, desaturate, channelOrder);
}

} // namespace AnonAlgo

#endif // ANONYMIZER_ALGO_H
