/*
** Multi-Layer Anonymizer - FxPlug 4 tileable effect implementation.
**
** Same algorithm as the Premiere Pro and OFX plugins: value-noise distortion
** -> Gaussian blur -> mosaic, plus a Blackout override. The shared buffer
** kernels run unmodified; FxPlug-specific copy-in/copy-out shaders bridge
** the host's IOSurface-backed textures (see FxPlugExtraKernels.h).
*/

#import "AnonymizerPlugIn.h"
#import "AnonMetalCache.h"

#import <IOSurface/IOSurfaceObjC.h>
#import <Metal/Metal.h>

#include "AnonymizerAlgo.h"

enum
{
	kParamID_DistortAmount = 1,
	kParamID_DistortScale = 2,
	kParamID_BlurRadius = 3,
	kParamID_MosaicSize = 4,
	kParamID_Seed = 5,
	kParamID_TemporalJitter = 6,
	kParamID_Blackout = 7,
};

typedef struct
{
	double distortAmount;
	double distortScale;
	double blurRadius;
	double mosaicSize;
	uint32_t seed;
	int32_t blackout;
} AnonFxState;

/*
** Mirrors struct AnonParams in shared/AnonymizerKernel.h.
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
	float mDistortAmount;
	float mDistortScale;
	float mBlurSigma;
	float mMosaicSize;
	uint32_t mSeed;
} AnonParamsHost;

typedef struct { int width; int height; } AnonCopyParamsHost;
typedef struct { int width; int height; int tileOffsetX; int tileOffsetY; } AnonOutParamsHost;

@implementation AnonymizerFxPlugIn

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager
{
	self = [super init];
	if (self != nil)
	{
		_apiManager = newApiManager;
	}
	return self;
}

- (BOOL)properties:(NSDictionary * _Nonnull *)properties
             error:(NSError * _Nullable *)error
{
	*properties = @{
		kFxPropertyKey_MayRemapTime : @NO,
		kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
		// Temporal Jitter changes the picture even with static parameters.
		kFxPropertyKey_VariesWhenParamsAreStatic : @YES,
	};
	return YES;
}

- (BOOL)addParametersWithError:(NSError**)error
{
	id<FxParameterCreationAPI_v5> paramAPI =
		[_apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
	if (paramAPI == nil)
	{
		if (error != NULL)
			*error = [NSError errorWithDomain:FxPlugErrorDomain
			                             code:kFxError_APIUnavailable
			                         userInfo:@{ NSLocalizedDescriptionKey :
			                             @"Unable to obtain the FxParameterCreationAPI_v5" }];
		return NO;
	}

	BOOL ok = YES;
	ok = ok && [paramAPI addFloatSliderWithName:@"Distortion Amount"
	                                parameterID:kParamID_DistortAmount
	                               defaultValue:DISTORT_AMOUNT_DFLT
	                               parameterMin:DISTORT_AMOUNT_MIN
	                               parameterMax:DISTORT_AMOUNT_MAX
	                                  sliderMin:DISTORT_AMOUNT_MIN
	                                  sliderMax:DISTORT_AMOUNT_MAX
	                                      delta:0.1
	                             parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addFloatSliderWithName:@"Distortion Scale"
	                                parameterID:kParamID_DistortScale
	                               defaultValue:DISTORT_SCALE_DFLT
	                               parameterMin:DISTORT_SCALE_MIN
	                               parameterMax:DISTORT_SCALE_MAX
	                                  sliderMin:DISTORT_SCALE_MIN
	                                  sliderMax:DISTORT_SCALE_MAX
	                                      delta:0.1
	                             parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addFloatSliderWithName:@"Blur Radius"
	                                parameterID:kParamID_BlurRadius
	                               defaultValue:BLUR_RADIUS_DFLT
	                               parameterMin:BLUR_RADIUS_MIN
	                               parameterMax:BLUR_RADIUS_MAX
	                                  sliderMin:BLUR_RADIUS_MIN
	                                  sliderMax:BLUR_RADIUS_MAX
	                                      delta:0.1
	                             parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addFloatSliderWithName:@"Mosaic Block Size"
	                                parameterID:kParamID_MosaicSize
	                               defaultValue:MOSAIC_SIZE_DFLT
	                               parameterMin:MOSAIC_SIZE_MIN
	                               parameterMax:MOSAIC_SIZE_MAX
	                                  sliderMin:MOSAIC_SIZE_MIN
	                                  sliderMax:MOSAIC_SIZE_MAX
	                                      delta:1.0
	                             parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addIntSliderWithName:@"Random Seed"
	                              parameterID:kParamID_Seed
	                             defaultValue:(int)SEED_DFLT
	                             parameterMin:(int)SEED_MIN
	                             parameterMax:(int)SEED_MAX
	                                sliderMin:(int)SEED_MIN
	                                sliderMax:(int)SEED_MAX
	                                    delta:1
	                           parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addToggleButtonWithName:@"Temporal Jitter"
	                                 parameterID:kParamID_TemporalJitter
	                                defaultValue:YES
	                              parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addToggleButtonWithName:@"Blackout"
	                                 parameterID:kParamID_Blackout
	                                defaultValue:NO
	                              parameterFlags:kFxParameterFlag_DEFAULT];

	if (!ok && error != NULL)
		*error = [NSError errorWithDomain:FxPlugErrorDomain
		                             code:kFxError_InvalidParameter
		                         userInfo:@{ NSLocalizedDescriptionKey :
		                             @"Unable to add Anonymizer parameters" }];
	return ok;
}

- (BOOL)pluginState:(NSData**)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError**)error
{
	id<FxParameterRetrievalAPI_v6> paramAPI =
		[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
	if (paramAPI == nil)
	{
		if (error != NULL)
			*error = [NSError errorWithDomain:FxPlugErrorDomain
			                             code:kFxError_APIUnavailable
			                         userInfo:@{ NSLocalizedDescriptionKey :
			                             @"Unable to obtain the FxParameterRetrievalAPI_v6" }];
		return NO;
	}

	AnonFxState state = {};
	BOOL jitterState = YES;
	BOOL blackoutState = NO;
	int seedValue = 0;
	[paramAPI getFloatValue:&state.distortAmount fromParameter:kParamID_DistortAmount atTime:renderTime];
	[paramAPI getFloatValue:&state.distortScale fromParameter:kParamID_DistortScale atTime:renderTime];
	[paramAPI getFloatValue:&state.blurRadius fromParameter:kParamID_BlurRadius atTime:renderTime];
	[paramAPI getFloatValue:&state.mosaicSize fromParameter:kParamID_MosaicSize atTime:renderTime];
	[paramAPI getIntValue:&seedValue fromParameter:kParamID_Seed atTime:renderTime];
	[paramAPI getBoolValue:&jitterState fromParameter:kParamID_TemporalJitter atTime:renderTime];
	[paramAPI getBoolValue:&blackoutState fromParameter:kParamID_Blackout atTime:renderTime];
	state.blackout = blackoutState ? 1 : 0;

	// Frame index for the temporal jitter, derived from the timeline frame
	// rate. Falls back to seconds * 30 if the timing API is unavailable.
	int32_t frame = 0;
	id<FxTimingAPI_v4> timingAPI = [_apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
	double seconds = CMTIME_IS_NUMERIC(renderTime) ? CMTimeGetSeconds(renderTime) : 0.0;
	if (timingAPI != nil)
	{
		NSUInteger fpsNum = [timingAPI timelineFpsNumeratorForEffect:self];
		NSUInteger fpsDen = [timingAPI timelineFpsDenominatorForEffect:self];
		if (fpsNum > 0 && fpsDen > 0)
			frame = (int32_t)llround(seconds * (double)fpsNum / (double)fpsDen);
	}
	else
	{
		frame = (int32_t)llround(seconds * 30.0);
	}
	state.seed = AnonComputeSeed((double)seedValue, jitterState, frame);

	*pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
	return *pluginState != nil;
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(nonnull FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError * _Nullable *)outError
{
	if (sourceImages.count < 1)
		return NO;
	*destinationImageRect = sourceImages[0].imagePixelBounds;
	return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
      sourceImageIndex:(NSUInteger)sourceImageIndex
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect
      destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError * _Nullable *)outError
{
	// Distortion, blur and mosaic are spatial: any output tile needs the
	// whole source frame.
	*sourceTileRect = sourceImages[sourceImageIndex].imagePixelBounds;
	return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError * _Nullable *)outError
{
	if ((pluginState == nil) || (pluginState.length < sizeof(AnonFxState))
		|| (sourceImages.count < 1)
		|| (sourceImages[0].ioSurface == nil) || (destinationImage.ioSurface == nil))
	{
		if (outError != NULL)
			*outError = [NSError errorWithDomain:FxPlugErrorDomain
			                                code:kFxError_InvalidParameter
			                            userInfo:@{ NSLocalizedDescriptionKey :
			                                @"Invalid state or images in render" }];
		return NO;
	}

	AnonFxState state = {};
	[pluginState getBytes:&state length:sizeof(state)];

	AnonMetalCacheEntry* cache = [[AnonMetalCache sharedCache]
		entryForDeviceRegistryID:destinationImage.deviceRegistryID];
	if (cache == nil)
		return NO;
	id<MTLDevice> device = cache.device;

	FxImageTile* srcImage = sourceImages[0];
	const FxRect srcTile = srcImage.tilePixelBounds;
	const FxRect dstTile = destinationImage.tilePixelBounds;
	const int width = srcTile.right - srcTile.left;    // full frame (we request it)
	const int height = srcTile.top - srcTile.bottom;
	const int dstWidth = dstTile.right - dstTile.left;
	const int dstHeight = dstTile.top - dstTile.bottom;
	if (width <= 0 || height <= 0 || dstWidth <= 0 || dstHeight <= 0)
		return NO;

	// Dst tile position within the full frame, in texture-row space.
	const int tileOffsetX = dstTile.left - srcTile.left;
	const int tileOffsetY = (destinationImage.imageOrigin == kFxImageOrigin_TOP_LEFT)
		? (srcTile.top - dstTile.top)
		: (dstTile.bottom - srcTile.bottom);

	// Scale pixel-space parameters by the render scale (pixelTransform maps
	// pixels to canonical 100%-scale units).
	float ds = 1.0f;
	{
		FxMatrix44* xform = destinationImage.pixelTransform;
		if (xform != nil)
		{
			FxPoint2D p0 = [xform transform2DPoint:(FxPoint2D){0.0, 0.0}];
			FxPoint2D p1 = [xform transform2DPoint:(FxPoint2D){1.0, 0.0}];
			double canonicalPerPixel = hypot(p1.x - p0.x, p1.y - p0.y);
			if (canonicalPerPixel > 0.0)
				ds = (float)(1.0 / canonicalPerPixel);
		}
		if (ds <= 0.0f || ds > 1.0f)
			ds = 1.0f;
	}

	id<MTLTexture> srcTexture = [srcImage metalTextureForDevice:device];
	id<MTLTexture> dstTexture = [destinationImage metalTextureForDevice:device];
	if (srcTexture == nil || dstTexture == nil)
		return NO;

	MTLPixelFormat dstFormat = dstTexture.pixelFormat;
	id<MTLRenderPipelineState> outputPipeline = [cache renderPipelineForPixelFormat:dstFormat];
	if (outputPipeline == nil)
		return NO;

	const size_t bufBytes = (size_t)width * height * 4 * sizeof(float);
	id<MTLBuffer> bufSrc = [device newBufferWithLength:bufBytes options:MTLResourceStorageModePrivate];
	id<MTLBuffer> bufA = [device newBufferWithLength:bufBytes options:MTLResourceStorageModePrivate];
	id<MTLBuffer> bufB = [device newBufferWithLength:bufBytes options:MTLResourceStorageModePrivate];
	if (bufSrc == nil || bufA == nil || bufB == nil)
		return NO;

	AnonParamsHost params = {};
	params.mSrcPitch = width;
	params.mDstPitch = width;
	params.m16f = 0;
	params.mWidth = width;
	params.mHeight = height;
	params.mBlurRadius = (int)fminf(ceilf((float)state.blurRadius * ds), 256.0f);
	params.mBlurDir = 0;
	params.mDistortAmount = (float)state.distortAmount * ds;
	params.mDistortScale = fmaxf((float)state.distortScale * ds, 2.0f);
	params.mBlurSigma = fmaxf((float)state.blurRadius * ds * 0.5f, 0.1f);
	params.mMosaicSize = (float)state.mosaicSize * ds;
	params.mSeed = state.seed;

	id<MTLCommandBuffer> commandBuffer = [cache.queue commandBuffer];
	commandBuffer.label = @"MultiLayerAnonymizer";
	id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];

	MTLSize threadsPerGroup = {16, 16, 1};
	MTLSize fullGrid = {
		(NSUInteger)((width + 15) / 16),
		(NSUInteger)((height + 15) / 16),
		1};

	// Copy the source texture into a packed float buffer.
	AnonCopyParamsHost copyParams = { width, height };
	[compute setComputePipelineState:cache.psoCopyIn];
	[compute setTexture:srcTexture atIndex:0];
	[compute setBuffer:bufSrc offset:0 atIndex:0];
	[compute setBytes:&copyParams length:sizeof(copyParams) atIndex:1];
	[compute dispatchThreadgroups:fullGrid threadsPerThreadgroup:threadsPerGroup];

	// Run the layered passes (or blackout) over the full frame; result in bufB.
	void (^dispatchPass)(id<MTLComputePipelineState>, id<MTLBuffer>, id<MTLBuffer>) =
		^(id<MTLComputePipelineState> pso, id<MTLBuffer> src, id<MTLBuffer> dst)
	{
		[compute setComputePipelineState:pso];
		[compute setBuffer:src offset:0 atIndex:0];
		[compute setBuffer:dst offset:0 atIndex:1];
		[compute setBytes:&params length:sizeof(params) atIndex:2];
		[compute dispatchThreadgroups:fullGrid threadsPerThreadgroup:threadsPerGroup];
	};

	if (state.blackout)
	{
		dispatchPass(cache.psoBlackout, bufSrc, bufB);
	}
	else
	{
		dispatchPass(cache.psoDistort, bufSrc, bufA);
		if (params.mBlurRadius >= 1)
		{
			params.mBlurDir = 0;
			dispatchPass(cache.psoBlur, bufA, bufB);
			params.mBlurDir = 1;
			dispatchPass(cache.psoBlur, bufB, bufA);
		}
		dispatchPass(cache.psoMosaic, bufA, bufB);
	}
	[compute endEncoding];

	// Write the result into the destination tile via a fullscreen quad.
	MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
	renderPass.colorAttachments[0].texture = dstTexture;
	renderPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> render = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];

	MTLViewport viewport = { 0, 0, (double)dstWidth, (double)dstHeight, -1.0, 1.0 };
	[render setViewport:viewport];
	[render setRenderPipelineState:outputPipeline];
	AnonOutParamsHost outParams = { width, height, tileOffsetX, tileOffsetY };
	[render setFragmentBuffer:bufB offset:0 atIndex:0];
	[render setFragmentBytes:&outParams length:sizeof(outParams) atIndex:1];
	[render drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[render endEncoding];

	[commandBuffer commit];
	[commandBuffer waitUntilCompleted];

	return commandBuffer.status == MTLCommandBufferStatusCompleted;
}

@end
