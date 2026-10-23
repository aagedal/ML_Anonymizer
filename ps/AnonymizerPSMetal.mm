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
	int mosaicShape, uint32_t seed, bool blurAfterMosaic, float desaturate,
	float cellNoise)
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
		AnonAlgo::DisplacementBias(w, h, scale, seed,
			&params.mDistortBiasDx, &params.mDistortBiasDy);
		params.mDesaturate = desaturate;
		params.mChannelOrder = ANON_ORDER_RGBA;
		params.mCellNoise = cellNoise;

		id<MTLCommandBuffer> commandBuffer = [sQueue commandBuffer];
		commandBuffer.label = @"MultiLayerAnonymizerPS";
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

		/* Distortion, then blur/mosaic in the selected order; result in dst. */
		DispatchPass(encoder, sPipelines[kKernelDistort], src, tmpA, params);
		if (blurAfterMosaic && params.mBlurRadius >= 1)
		{
			DispatchPass(encoder, sPipelines[kKernelMosaic], tmpA, tmpB, params);
			params.mBlurDir = 0;
			DispatchPass(encoder, sPipelines[kKernelBlur], tmpB, tmpA, params);
			params.mBlurDir = 1;
			DispatchPass(encoder, sPipelines[kKernelBlur], tmpA, dst, params);
		}
		else
		{
			if (params.mBlurRadius >= 1)
			{
				params.mBlurDir = 0;
				DispatchPass(encoder, sPipelines[kKernelBlur], tmpA, tmpB, params);
				params.mBlurDir = 1;
				DispatchPass(encoder, sPipelines[kKernelBlur], tmpB, tmpA, params);
			}
			DispatchPass(encoder, sPipelines[kKernelMosaic], tmpA, dst, params);
		}

		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if (commandBuffer.error != nil)
			return false;

		memcpy(buf, dst.contents, bytes);
		return true;
	}
}
