/*
** Multi-Layer Anonymizer - Photoshop filter plugin (Metal render path).
**
** Runs the full-resolution render on the GPU with the exact MSL kernels
** shared with the Premiere / Resolve / FCP plugins. Unlike those hosts,
** Photoshop gives us no device or queue, so the plugin owns both; the
** packed RGBA float buffer is copied in and out of shared MTLBuffers.
** Any failure returns false and the caller falls back to the CPU path,
** which produces identical output (verified to ~1e-7 by the parity tests).
*/

#include "AnonymizerPS.h"

#import <Metal/Metal.h>

#include "AnonymizerKernel.h"
#include "AnonymizerAlgo.h"

#include <algorithm>
#include <string.h>

/*
** Mirrors struct AnonParams in AnonymizerKernel.h (all 32-bit fields).
** Must stay byte-for-byte in sync with that struct.
*/
typedef struct
{
	int mSrcPitch;
	int mDstPitch;
	int m16f;
	int mWidth;
	int mHeight;
	int mBlurRadius;
	int mBlurDir;
	int mMosaicShape;
	float mDistortAmount;
	float mDistortScale;
	float mBlurSigma;
	float mMosaicSize;
	uint32_t mSeed;
	float mDistortBiasDx;
	float mDistortBiasDy;
} AnonParamsHost;

enum { kKernelDistort = 0, kKernelBlur, kKernelMosaic, kKernelCount };
static const char* const kKernelNames[kKernelCount] =
	{ "AnonDistort", "AnonBlur", "AnonMosaic" };

static id<MTLDevice> sDevice = nil;
static id<MTLCommandQueue> sQueue = nil;
static id<MTLComputePipelineState> sPipelines[kKernelCount] = {};
static bool sInitTried = false;
static bool sInitOK = false;

static bool EnsurePipelines(void)
{
	if (sInitTried)
		return sInitOK;
	sInitTried = true;

	sDevice = MTLCreateSystemDefaultDevice();
	if (sDevice == nil)
		return false;
	sQueue = [sDevice newCommandQueue];
	if (sQueue == nil)
		return false;

	NSError* err = nil;
	MTLCompileOptions* options = [MTLCompileOptions new];
	/* Precise math so cell/pixel selection matches the CPU path exactly. */
	options.mathMode = MTLMathModeSafe;
	id<MTLLibrary> library = [sDevice newLibraryWithSource:@(kAnonymizerMetalString)
		options:options error:&err];
	if (library == nil)
		return false;

	for (int k = 0; k < kKernelCount; ++k)
	{
		id<MTLFunction> function = [library newFunctionWithName:
			[NSString stringWithUTF8String:kKernelNames[k]]];
		if (function == nil)
			return false;
		sPipelines[k] = [sDevice newComputePipelineStateWithFunction:function error:&err];
		if (sPipelines[k] == nil)
			return false;
	}

	sInitOK = true;
	return true;
}

static void DispatchPass(
	id<MTLComputeCommandEncoder> encoder,
	id<MTLComputePipelineState> pipeline,
	id<MTLBuffer> src,
	id<MTLBuffer> dst,
	const AnonParamsHost& params)
{
	[encoder setComputePipelineState:pipeline];
	[encoder setBuffer:src offset:0 atIndex:0];
	[encoder setBuffer:dst offset:0 atIndex:1];
	[encoder setBytes:&params length:sizeof(params) atIndex:2];
	MTLSize threadsPerGroup = {16, 16, 1};
	MTLSize numThreadgroups = {
		(NSUInteger)((params.mWidth + 15) / 16),
		(NSUInteger)((params.mHeight + 15) / 16),
		1};
	[encoder dispatchThreadgroups:numThreadgroups threadsPerThreadgroup:threadsPerGroup];
}

bool RunMetalPasses(float* buf, int w, int h,
	float amount, float scale, float blurRadius, float mosaicSize,
	int mosaicShape, uint32_t seed)
{
	@autoreleasepool
	{
		if (!EnsurePipelines())
			return false;

		const size_t bytes = (size_t)w * h * 4 * sizeof(float);
		id<MTLBuffer> src = [sDevice newBufferWithBytes:buf length:bytes
			options:MTLResourceStorageModeShared];
		id<MTLBuffer> dst = [sDevice newBufferWithLength:bytes
			options:MTLResourceStorageModeShared];
		id<MTLBuffer> tmpA = [sDevice newBufferWithLength:bytes
			options:MTLResourceStorageModePrivate];
		id<MTLBuffer> tmpB = [sDevice newBufferWithLength:bytes
			options:MTLResourceStorageModePrivate];
		if (src == nil || dst == nil || tmpA == nil || tmpB == nil)
			return false;

		/* Sparse-grid mean bias - same approach as the other GPU hosts. */
		const float invScaleBias = 1.0f / std::max(scale, 2.0f);
		const int kBiasStep = std::max(1, std::max(w, h) / 64);
		float sumBiasDx = 0.0f, sumBiasDy = 0.0f;
		int biasSamples = 0;
		for (int sy = kBiasStep / 2; sy < h; sy += kBiasStep) {
			for (int sx = kBiasStep / 2; sx < w; sx += kBiasStep) {
				sumBiasDx += AnonAlgo::VNoise((float)sx * invScaleBias, (float)sy * invScaleBias, seed, 0u);
				sumBiasDy += AnonAlgo::VNoise((float)sx * invScaleBias, (float)sy * invScaleBias, seed, 1u);
				++biasSamples;
			}
		}

		AnonParamsHost params = {};
		params.mSrcPitch = w;
		params.mDstPitch = w;
		params.m16f = 0;
		params.mWidth = w;
		params.mHeight = h;
		params.mDistortAmount = amount;
		params.mDistortScale = scale;
		params.mBlurRadius = std::min((int)ceilf(blurRadius), 512);
		params.mBlurSigma = std::max(blurRadius * 0.5f, 0.1f);
		params.mMosaicSize = mosaicSize;
		params.mMosaicShape = mosaicShape;
		params.mSeed = seed;
		params.mDistortBiasDx = biasSamples > 0
			? (sumBiasDx / (float)biasSamples) * 2.0f - 1.0f : 0.0f;
		params.mDistortBiasDy = biasSamples > 0
			? (sumBiasDy / (float)biasSamples) * 2.0f - 1.0f : 0.0f;

		id<MTLCommandBuffer> commandBuffer = [sQueue commandBuffer];
		commandBuffer.label = @"MultiLayerAnonymizerPS";
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

		/* src -> distort -> A -> blurH -> B -> blurV -> A -> mosaic -> dst */
		DispatchPass(encoder, sPipelines[kKernelDistort], src, tmpA, params);
		if (params.mBlurRadius >= 1)
		{
			params.mBlurDir = 0;
			DispatchPass(encoder, sPipelines[kKernelBlur], tmpA, tmpB, params);
			params.mBlurDir = 1;
			DispatchPass(encoder, sPipelines[kKernelBlur], tmpB, tmpA, params);
		}
		DispatchPass(encoder, sPipelines[kKernelMosaic], tmpA, dst, params);

		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if (commandBuffer.error != nil)
			return false;

		memcpy(buf, dst.contents, bytes);
		return true;
	}
}
