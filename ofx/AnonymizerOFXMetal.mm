/*
** Multi-Layer Anonymizer OFX - Metal host code.
**
** Reuses the exact same MSL kernels as the Premiere Pro plugin
** (shared/AnonymizerKernel.h). Resolve hands the plugin an MTLCommandQueue
** and images whose pixel pointers are really id<MTLBuffer> (see Blackmagic's
** GainPlugin sample). OFX GPU images are packed RGBA float, pitch == width;
** alpha is component .w in both RGBA and BGRA, so the kernels are reused
** unmodified with is16f = 0.
*/

#import <Metal/Metal.h>

#include <unordered_map>
#include <mutex>
#include <math.h>
#include <algorithm>
#include <stdint.h>

#include "AnonymizerKernel.h"
#include "AnonymizerAlgo.h"

struct AnonRenderSettings
{
	float distortAmount;
	float distortScale;
	float blurRadius;
	float mosaicSize;
	uint32_t seed;
	bool blackout;
	int mosaicShape;
	bool blurAfterMosaic;
};

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

enum { kKernelDistort = 0, kKernelBlur, kKernelMosaic, kKernelBlackout, kKernelCount };
static const char* const kKernelNames[kKernelCount] = { "AnonDistort", "AnonBlur", "AnonMosaic", "AnonBlackout" };

struct AnonPipelines
{
	id<MTLComputePipelineState> p[kKernelCount];
};

static std::mutex s_PipelineQueueMutex;
static std::unordered_map<id<MTLCommandQueue>, AnonPipelines> s_PipelineQueueMap;

static bool GetPipelines(id<MTLCommandQueue> p_Queue, AnonPipelines& outPipelines)
{
	std::unique_lock<std::mutex> lock(s_PipelineQueueMutex);

	const auto it = s_PipelineQueueMap.find(p_Queue);
	if (it != s_PipelineQueueMap.end())
	{
		outPipelines = it->second;
		return true;
	}

	id<MTLDevice> device = p_Queue.device;
	NSError* err = nil;

	MTLCompileOptions* options = [MTLCompileOptions new];
	// Precise math so cell/pixel selection matches the CPU path exactly.
	options.mathMode = MTLMathModeSafe;
	id<MTLLibrary> library = [device newLibraryWithSource:@(kAnonymizerMetalString) options:options error:&err];
	[options release];
	if (!library)
	{
		fprintf(stderr, "Anonymizer OFX: failed to compile Metal library: %s\n",
			err.localizedDescription.UTF8String);
		return false;
	}

	AnonPipelines pipelines = {};
	for (int k = 0; k < kKernelCount; ++k)
	{
		id<MTLFunction> function = [library newFunctionWithName:
			[NSString stringWithUTF8String:kKernelNames[k]]];
		if (!function)
		{
			[library release];
			return false;
		}
		pipelines.p[k] = [device newComputePipelineStateWithFunction:function error:&err];
		[function release];
		if (!pipelines.p[k])
		{
			fprintf(stderr, "Anonymizer OFX: failed to create pipeline %s: %s\n",
				kKernelNames[k], err.localizedDescription.UTF8String);
			[library release];
			return false;
		}
	}
	[library release];

	s_PipelineQueueMap[p_Queue] = pipelines;
	outPipelines = pipelines;
	return true;
}

static void DispatchPass(
	id<MTLComputeCommandEncoder> p_Encoder,
	id<MTLComputePipelineState> p_Pipeline,
	id<MTLBuffer> p_Src,
	id<MTLBuffer> p_Dst,
	const AnonParamsHost& p_Params)
{
	[p_Encoder setComputePipelineState:p_Pipeline];
	[p_Encoder setBuffer:p_Src offset:0 atIndex:0];
	[p_Encoder setBuffer:p_Dst offset:0 atIndex:1];
	[p_Encoder setBytes:&p_Params length:sizeof(p_Params) atIndex:2];
	MTLSize threadsPerGroup = {16, 16, 1};
	MTLSize numThreadgroups = {
		(NSUInteger)((p_Params.mWidth + 15) / 16),
		(NSUInteger)((p_Params.mHeight + 15) / 16),
		1};
	[p_Encoder dispatchThreadgroups:numThreadgroups threadsPerThreadgroup:threadsPerGroup];
}

void RunMetalAnonymizer(void* p_CmdQ, int p_Width, int p_Height,
	const float* p_Input, float* p_Output, const AnonRenderSettings& p_Settings)
{
	// Plugins must not rely on a host autorelease pool.
	@autoreleasepool {

	id<MTLCommandQueue> queue = static_cast<id<MTLCommandQueue>>(p_CmdQ);
	id<MTLDevice> device = queue.device;

	AnonPipelines pipelines;
	if (!GetPipelines(queue, pipelines))
		return;

	id<MTLBuffer> srcBuffer = reinterpret_cast<id<MTLBuffer>>(const_cast<float*>(p_Input));
	id<MTLBuffer> dstBuffer = reinterpret_cast<id<MTLBuffer>>(p_Output);

	// Sparse-grid mean bias — same approach as the Premiere GPU path.
	const float invScaleBias = 1.0f / std::max(p_Settings.distortScale, 2.0f);
	const int kBiasStep = std::max(1, std::max(p_Width, p_Height) / 64);
	float sumBiasDx = 0.0f, sumBiasDy = 0.0f;
	int biasSamples = 0;
	for (int sy = kBiasStep / 2; sy < p_Height; sy += kBiasStep) {
		for (int sx = kBiasStep / 2; sx < p_Width; sx += kBiasStep) {
			sumBiasDx += AnonAlgo::VNoise((float)sx * invScaleBias, (float)sy * invScaleBias, p_Settings.seed, 0u);
			sumBiasDy += AnonAlgo::VNoise((float)sx * invScaleBias, (float)sy * invScaleBias, p_Settings.seed, 1u);
			++biasSamples;
		}
	}
	const float distortBiasDx = biasSamples > 0 ? (sumBiasDx / (float)biasSamples) * 2.0f - 1.0f : 0.0f;
	const float distortBiasDy = biasSamples > 0 ? (sumBiasDy / (float)biasSamples) * 2.0f - 1.0f : 0.0f;

	AnonParamsHost params = {};
	params.mSrcPitch = p_Width;
	params.mDstPitch = p_Width;
	params.m16f = 0;
	params.mWidth = p_Width;
	params.mHeight = p_Height;
	params.mDistortAmount = p_Settings.distortAmount;
	params.mDistortScale = p_Settings.distortScale;
	params.mBlurRadius = std::min((int)ceilf(p_Settings.blurRadius), 512);
	params.mBlurSigma = std::max(p_Settings.blurRadius * 0.5f, 0.1f);
	params.mMosaicSize = p_Settings.mosaicSize;
	params.mMosaicShape = p_Settings.mosaicShape;
	params.mSeed = p_Settings.seed;
	params.mDistortBiasDx = distortBiasDx;
	params.mDistortBiasDy = distortBiasDy;

	id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
	commandBuffer.label = @"MultiLayerAnonymizer";
	id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

	if (p_Settings.blackout)
	{
		DispatchPass(encoder, pipelines.p[kKernelBlackout], srcBuffer, dstBuffer, params);
		[encoder endEncoding];
		[commandBuffer commit];
		return;
	}

	// Two packed temp buffers for the pass chain:
	// Distortion, then blur/mosaic in the selected order; result in dst.
	const size_t tmpBytes = (size_t)p_Width * p_Height * 4 * sizeof(float);
	id<MTLBuffer> tmpA = [device newBufferWithLength:tmpBytes options:MTLResourceStorageModePrivate];
	id<MTLBuffer> tmpB = [device newBufferWithLength:tmpBytes options:MTLResourceStorageModePrivate];

	DispatchPass(encoder, pipelines.p[kKernelDistort], srcBuffer, tmpA, params);
	if (p_Settings.blurAfterMosaic && params.mBlurRadius >= 1)
	{
		DispatchPass(encoder, pipelines.p[kKernelMosaic], tmpA, tmpB, params);
		params.mBlurDir = 0;
		DispatchPass(encoder, pipelines.p[kKernelBlur], tmpB, tmpA, params);
		params.mBlurDir = 1;
		DispatchPass(encoder, pipelines.p[kKernelBlur], tmpA, dstBuffer, params);
	}
	else
	{
		if (params.mBlurRadius >= 1)
		{
			params.mBlurDir = 0;
			DispatchPass(encoder, pipelines.p[kKernelBlur], tmpA, tmpB, params);
			params.mBlurDir = 1;
			DispatchPass(encoder, pipelines.p[kKernelBlur], tmpB, tmpA, params);
		}
		DispatchPass(encoder, pipelines.p[kKernelMosaic], tmpA, dstBuffer, params);
	}

	[encoder endEncoding];
	[commandBuffer addCompletedHandler:^(id<MTLCommandBuffer>) {
		[tmpA release];
		[tmpB release];
	}];
	[commandBuffer commit];

	} // @autoreleasepool
}
