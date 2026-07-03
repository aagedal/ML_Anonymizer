/*
** Multi-Layer Anonymizer - GPU render path (Metal).
**
** Premiere Pro binds this GPU filter to the AE-style effect in the same
** binary via the PiPL match name (PrGPUFilterInfo::outMatchName is left null,
** which defaults to the module's PiPL - see PrSDKGPUFilter.h).
**
** Render pipeline (all on the GPU, no readbacks):
**   input -> AnonDistort -> tmpA -> AnonBlur(H) -> tmpB -> AnonBlur(V)
**         -> tmpA -> AnonMosaic -> output
*/

#include "Anonymizer.h"

#include "PrGPUFilterModule.h"
#include "PrSDKVideoSegmentProperties.h"

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "AnonymizerKernel.h"

#include <math.h>
#include <algorithm>

/*
** Mirrors struct AnonParams in AnonymizerKernel.h (all 32-bit fields).
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

static prSuiteError CheckForMetalError(NSError* inError)
{
	if (inError)
	{
		// For debugging: NSLog(@"Anonymizer Metal error: %@", [inError localizedDescription]);
		return suiteError_Fail;
	}
	return suiteError_NoError;
}

static size_t DivideRoundUp(size_t inValue, size_t inMultiple)
{
	return inValue ? (inValue + inMultiple - 1) / inMultiple : 0;
}

/*
** Plugins must not rely on a host autorelease pool (see SDK_ProcAmp sample).
*/
struct ScopedAutoreleasePool
{
	ScopedAutoreleasePool() : mPool([[NSAutoreleasePool alloc] init]) {}
	~ScopedAutoreleasePool() { [mPool release]; }
	NSAutoreleasePool* mPool;
};

enum { kMaxDevices = 12 };
enum { kKernelDistort = 0, kKernelBlur, kKernelMosaic, kKernelBlackout, kKernelCount };
static id<MTLComputePipelineState> sPipelineCache[kMaxDevices][kKernelCount] = {};

static const char* const kKernelNames[kKernelCount] = { "AnonDistort", "AnonBlur", "AnonMosaic", "AnonBlackout" };

/*
**
*/
class Anonymizer :
	public PrGPUFilterBase
{
public:
	virtual prSuiteError Initialize(
		PrGPUFilterInstance* ioInstanceData)
	{
		PrGPUFilterBase::Initialize(ioInstanceData);

		if (mDeviceIndex >= kMaxDevices)
			return suiteError_Fail;

		// This plugin accelerates Metal only. Returning an error here makes
		// Premiere fall back to the software path in Anonymizer_CPU.cpp for
		// other frameworks (OpenCL/CUDA/DirectX).
		if (mDeviceInfo.outDeviceFramework != PrGPUDeviceFramework_Metal)
			return suiteError_Fail;

		if (sPipelineCache[mDeviceIndex][0])
		{
			for (int k = 0; k < kKernelCount; ++k)
				mPipelines[k] = sPipelineCache[mDeviceIndex][k];
			return suiteError_NoError;
		}

		ScopedAutoreleasePool pool;
		prSuiteError result = suiteError_NoError;

		NSString* source = [NSString stringWithCString:kAnonymizerMetalString encoding:NSUTF8StringEncoding];
		NSError* error = nil;
		id<MTLDevice> device = (id<MTLDevice>)mDeviceInfo.outDeviceHandle;
		// Precise math so cell/pixel selection matches the CPU path exactly;
		// fast-math's approximate division flips mosaic cells at boundaries.
		MTLCompileOptions* options = [[[MTLCompileOptions alloc] init] autorelease];
		options.mathMode = MTLMathModeSafe;
		id<MTLLibrary> library = [[device newLibraryWithSource:source options:options error:&error] autorelease];
		result = CheckForMetalError(error);
		if (result != suiteError_NoError)
			return result;

		for (int k = 0; k < kKernelCount; ++k)
		{
			NSString* name = [NSString stringWithCString:kKernelNames[k] encoding:NSUTF8StringEncoding];
			id<MTLFunction> function = [[library newFunctionWithName:name] autorelease];
			if (!function)
				return suiteError_Fail;
			mPipelines[k] = [device newComputePipelineStateWithFunction:function error:&error];
			result = CheckForMetalError(error);
			if (result != suiteError_NoError)
				return result;
			sPipelineCache[mDeviceIndex][k] = mPipelines[k];
		}
		return suiteError_NoError;
	}

	prSuiteError Render(
		const PrGPUFilterRenderParams* inRenderParams,
		const PPixHand* inFrames,
		csSDK_size_t inFrameCount,
		PPixHand* outFrame)
	{
		if (!outFrame || !*outFrame)
			return suiteError_Fail;

		// For effects (unlike transitions) the host delivers *outFrame
		// pre-filled with the source pixels, and the SDK allows rendering in
		// place (see SDK_ProcAmp_GPU / Vignette_GPU). Operating on *outFrame
		// directly preserves the frame's bounds and placement metadata.
		// Replacing it with a CreateGPUPPix frame resets the bounds origin to
		// (0,0), which shifted clips whose aspect ratio doesn't match the
		// sequence. Reads and writes never alias: the multi-pass chain reads
		// the frame only in the first pass and writes it only in the last,
		// and blackout touches each pixel exactly once.
		PPixHand ioPPix = *outFrame;

		// ---- Frame geometry ----
		PrPixelFormat pixelFormat = PrPixelFormat_Invalid;
		mPPixSuite->GetPixelFormat(ioPPix, &pixelFormat);

		prRect bounds = {};
		mPPixSuite->GetBounds(ioPPix, &bounds);
		const int width = bounds.right - bounds.left;
		const int height = bounds.bottom - bounds.top;
		if (width <= 0 || height <= 0)
			return suiteError_Fail;

		const int bytesPerPixel = GetGPUBytesPerPixel(pixelFormat);
		const int is16f = pixelFormat != PrPixelFormat_GPU_BGRA_4444_32f;

		csSDK_int32 rowBytes = 0;
		mPPixSuite->GetRowBytes(ioPPix, &rowBytes);
		const int srcPitch = rowBytes / bytesPerPixel;
		const int dstPitch = srcPitch;

		void* frameData = 0;
		mGPUDeviceSuite->GetGPUPPixData(ioPPix, &frameData);
		if (!frameData)
			return suiteError_Fail;
		void* srcFrameData = frameData;
		void* dstFrameData = frameData;

		// ---- Parameters ----
		const PrTime clipTime = inRenderParams->inClipTime;

		// Pixel-space parameters are relative to 1080p; the shorter frame
		// dimension already reflects any preview downsampling and is
		// orientation-invariant (portrait vs landscape timelines).
		const float ds = AnonResolutionScale(width, height);

		const float distortAmount = (float)GetParam(ANON_DISTORT_AMOUNT, clipTime).mFloat64 * ds;
		const float distortScale = std::max((float)GetParam(ANON_DISTORT_SCALE, clipTime).mFloat64 * ds, 2.0f);
		const float blurRadius = (float)GetParam(ANON_BLUR_RADIUS, clipTime).mFloat64 * ds;
		const float mosaicSize = (float)GetParam(ANON_MOSAIC_SIZE, clipTime).mFloat64 * ds;
		const double seedParam = GetParam(ANON_SEED, clipTime).mFloat64;
		const bool jitter = GetParam(ANON_TEMPORAL_JITTER, clipTime).mBool != 0;
		const bool blackout = GetParam(ANON_BLACKOUT, clipTime).mBool != 0;
		// Unlike the AE-style CPU side (u.pd.value, 1-based), the video
		// segment suite delivers popup values 0-based.
		int mosaicShape = (int)GetParam(ANON_MOSAIC_SHAPE, clipTime).mInt32;
		if (mosaicShape < ANON_SHAPE_SQUARE || mosaicShape > ANON_SHAPE_HEXAGON)
			mosaicShape = ANON_SHAPE_SQUARE;

		int32_t frame = 0;
		if (inRenderParams->inRenderTicksPerFrame != 0)
			frame = (int32_t)(clipTime / inRenderParams->inRenderTicksPerFrame);
		const uint32_t seed = AnonComputeSeed(seedParam, jitter, frame);

		// Compute the spatial mean of the noise displacement over the frame using a
		// sparse grid. Subtracting this mean anchors the net image translation to
		// zero for any seed, which is essential when temporal jitter changes the
		// seed every frame (otherwise the whole image bounces). VNoise is C1-smooth
		// so ~64 samples per axis give an accurate estimate with negligible overhead.
		const float invScaleBias = 1.0f / std::max(distortScale, 2.0f);
		const int kBiasStep = std::max(1, std::max(width, height) / 64);
		float sumBiasDx = 0.0f, sumBiasDy = 0.0f;
		int biasSamples = 0;
		for (int sy = kBiasStep / 2; sy < height; sy += kBiasStep) {
			for (int sx = kBiasStep / 2; sx < width; sx += kBiasStep) {
				sumBiasDx += AnonAlgo::VNoise((float)sx * invScaleBias, (float)sy * invScaleBias, seed, 0u);
				sumBiasDy += AnonAlgo::VNoise((float)sx * invScaleBias, (float)sy * invScaleBias, seed, 1u);
				++biasSamples;
			}
		}
		const float distortBiasDx = biasSamples > 0 ? (sumBiasDx / (float)biasSamples) * 2.0f - 1.0f : 0.0f;
		const float distortBiasDy = biasSamples > 0 ? (sumBiasDy / (float)biasSamples) * 2.0f - 1.0f : 0.0f;

		const int blurRadiusInt = std::min((int)ceilf(blurRadius), 512);
		const float blurSigma = std::max(blurRadius * 0.5f, 0.1f);

		// Blackout short-circuits the whole stack: one pass, no temp buffers.
		if (blackout)
		{
			ScopedAutoreleasePool blackoutPool;
			id<MTLCommandQueue> queue = (id<MTLCommandQueue>)mDeviceInfo.outCommandQueueHandle;
			id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
			id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

			AnonParamsHost blackoutParams = {};
			blackoutParams.m16f = is16f;
			blackoutParams.mWidth = width;
			blackoutParams.mHeight = height;
			blackoutParams.mSrcPitch = srcPitch;
			blackoutParams.mDstPitch = dstPitch;
			Dispatch(encoder, mPipelines[kKernelBlackout],
				(id<MTLBuffer>)srcFrameData, (id<MTLBuffer>)dstFrameData, blackoutParams);

			[encoder endEncoding];
			[commandBuffer commit];
			return suiteError_NoError;
		}

		// ---- Encode the passes ----
		ScopedAutoreleasePool pool;

		id<MTLCommandQueue> queue = (id<MTLCommandQueue>)mDeviceInfo.outCommandQueueHandle;
		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

		id<MTLBuffer> srcBuffer = (id<MTLBuffer>)srcFrameData;
		id<MTLBuffer> dstBuffer = (id<MTLBuffer>)dstFrameData;

		// Temp buffers (packed, pitch == width) are allocated per render and
		// released by the command buffer's completion handler. Renders are
		// committed asynchronously and may overlap or vary in size (preview
		// vs full resolution), so instance-cached buffers would risk being
		// freed while an earlier command buffer still reads them.
		const size_t tmpBytes = (size_t)width * height * bytesPerPixel;
		id<MTLDevice> device = (id<MTLDevice>)mDeviceInfo.outDeviceHandle;
		id<MTLBuffer> tmpA = [device newBufferWithLength:tmpBytes options:MTLResourceStorageModePrivate];
		id<MTLBuffer> tmpB = [device newBufferWithLength:tmpBytes options:MTLResourceStorageModePrivate];
		if (tmpA == nil || tmpB == nil)
		{
			[tmpA release];
			[tmpB release];
			[encoder endEncoding];
			return suiteError_OutOfMemory;
		}

		AnonParamsHost params = {};
		params.m16f = is16f;
		params.mWidth = width;
		params.mHeight = height;
		params.mBlurRadius = blurRadiusInt;
		params.mMosaicShape = mosaicShape;
		params.mDistortAmount = distortAmount;
		params.mDistortScale = distortScale;
		params.mBlurSigma = blurSigma;
		params.mMosaicSize = mosaicSize;
		params.mSeed = seed;
		params.mDistortBiasDx = distortBiasDx;
		params.mDistortBiasDy = distortBiasDy;

		// Layer 1: distortion, input frame -> tmpA
		params.mSrcPitch = srcPitch;
		params.mDstPitch = width;
		Dispatch(encoder, mPipelines[kKernelDistort], srcBuffer, tmpA, params);

		// Layer 2: separable Gaussian blur, tmpA -> tmpB -> tmpA
		if (blurRadiusInt >= 1)
		{
			params.mSrcPitch = width;
			params.mDstPitch = width;
			params.mBlurDir = 0;
			Dispatch(encoder, mPipelines[kKernelBlur], tmpA, tmpB, params);
			params.mBlurDir = 1;
			Dispatch(encoder, mPipelines[kKernelBlur], tmpB, tmpA, params);
		}

		// Layer 3: mosaic, tmpA -> output frame
		params.mSrcPitch = width;
		params.mDstPitch = dstPitch;
		Dispatch(encoder, mPipelines[kKernelMosaic], tmpA, dstBuffer, params);

		[encoder endEncoding];
		[commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			[tmpA release];
			[tmpB release];
		}];
		[commandBuffer commit];

		return suiteError_NoError;
	}

private:
	void Dispatch(
		id<MTLComputeCommandEncoder> inEncoder,
		id<MTLComputePipelineState> inPipeline,
		id<MTLBuffer> inSrc,
		id<MTLBuffer> inDst,
		const AnonParamsHost& inParams)
	{
		[inEncoder setComputePipelineState:inPipeline];
		[inEncoder setBuffer:inSrc offset:0 atIndex:0];
		[inEncoder setBuffer:inDst offset:0 atIndex:1];
		[inEncoder setBytes:&inParams length:sizeof(inParams) atIndex:2];
		MTLSize threadsPerGroup = {16, 16, 1};
		MTLSize numThreadgroups = {
			DivideRoundUp(inParams.mWidth, threadsPerGroup.width),
			DivideRoundUp(inParams.mHeight, threadsPerGroup.height),
			1};
		[inEncoder dispatchThreadgroups:numThreadgroups threadsPerThreadgroup:threadsPerGroup];
	}


	id<MTLComputePipelineState> mPipelines[kKernelCount];
};


DECLARE_GPUFILTER_ENTRY(PrGPUFilterModule<Anonymizer>)
