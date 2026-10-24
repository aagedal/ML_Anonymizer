/*
** Multi-Layer Anonymizer - FxPlug 4 tileable effect implementation.
**
** Same algorithm as the Premiere Pro and OFX plugins: value-noise distortion
** -> Gaussian blur -> mosaic -> desaturation, plus a Blackout override. The
** shared buffer kernels run unmodified; FxPlug-specific copy-in/copy-out shaders bridge
** the host's IOSurface-backed textures (see FxPlugExtraKernels.h).
*/

#import "AnonymizerPlugIn.h"
#import "AnonMetalCache.h"

#import <IOSurface/IOSurfaceObjC.h>
#import <Metal/Metal.h>

#include "AnonymizerAlgo.h"
#include "AnonymizerKernel.h"

enum
{
	kParamID_DistortAmount = 1,
	kParamID_DistortScale = 2,
	kParamID_BlurRadius = 3,
	kParamID_MosaicSize = 4,
	kParamID_Seed = 5,
	kParamID_TemporalJitter = 6,
	kParamID_Blackout = 7,
	kParamID_MosaicShape = 8,
	kParamID_BlurAfterMosaic = 9,
	kParamID_Desaturate = 10,
	kParamID_SessionKey = 11,
	kParamID_RandomizeSeed = 12,
	kParamID_CellNoise = 13,
	kParamID_ColorNoise = 14,
	kParamID_EnableDistort = 15,
	kParamID_EnableBlur = 16,
	kParamID_EnableMosaic = 17,
};

typedef struct
{
	double distortAmount;
	double distortScale;
	double blurRadius;
	double mosaicSize;
	uint32_t seed;
	int32_t blackout;
	int32_t mosaicShape;
	int32_t blurAfterMosaic;
	double desaturate; // 0..100
	double cellNoise; // 0..100
	double colorNoise; // 0..100
	int32_t enableDistort;
	int32_t enableBlur;
	int32_t enableMosaic;
} AnonFxState;

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

- (BOOL)parameterChanged:(UInt32)paramID atTime:(CMTime)time error:(NSError**)error
{
	if (paramID != kParamID_BlurAfterMosaic)
		return YES;

	id<FxParameterRetrievalAPI_v6> retrieval = [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
	id<FxParameterSettingAPI_v5> setting = [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
	BOOL enabled = NO;
	double current = BLUR_RADIUS_DFLT;
	if (retrieval == nil || setting == nil ||
		![retrieval getBoolValue:&enabled fromParameter:kParamID_BlurAfterMosaic atTime:time] ||
		![retrieval getFloatValue:&current fromParameter:kParamID_BlurRadius atTime:time])
	{
		if (error != NULL)
			*error = [NSError errorWithDomain:FxPlugErrorDomain code:kFxError_APIUnavailable
				userInfo:@{NSLocalizedDescriptionKey: @"Unable to read blur parameters"}];
		return NO;
	}
	const double radius = AnonAlgo::BlurRadiusForOrderChange(current, enabled);
	if (radius != current && ![setting setFloatValue:radius toParameter:kParamID_BlurRadius atTime:time])
	{
		if (error != NULL)
			*error = [NSError errorWithDomain:FxPlugErrorDomain code:kFxError_InvalidParameter
				userInfo:@{NSLocalizedDescriptionKey: @"Unable to update Blur Radius"}];
		return NO;
	}
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

	// The strength sliders stop at their minimums; the Enable toggles switch
	// a layer off entirely, for previewing the others.
	BOOL ok = YES;
	ok = ok && [paramAPI addToggleButtonWithName:@"Enable Distortion"
	                                 parameterID:kParamID_EnableDistort
	                                defaultValue:YES
	                              parameterFlags:kFxParameterFlag_DEFAULT];
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
	ok = ok && [paramAPI addToggleButtonWithName:@"Enable Blur"
	                                 parameterID:kParamID_EnableBlur
	                                defaultValue:YES
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
	ok = ok && [paramAPI addToggleButtonWithName:@"Enable Mosaic"
	                                 parameterID:kParamID_EnableMosaic
	                                defaultValue:YES
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
	ok = ok && [paramAPI addPushButtonWithName:@"Randomize Seed"
	                               parameterID:kParamID_RandomizeSeed
	                                  selector:@selector(randomizeSeed)
	                            parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addToggleButtonWithName:@"Session Key"
	                                 parameterID:kParamID_SessionKey
	                                defaultValue:YES
	                              parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addToggleButtonWithName:@"Temporal Jitter"
	                                 parameterID:kParamID_TemporalJitter
	                                defaultValue:YES
	                              parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addToggleButtonWithName:@"Blackout"
	                                 parameterID:kParamID_Blackout
	                                defaultValue:NO
	                              parameterFlags:kFxParameterFlag_DEFAULT];
	ok = ok && [paramAPI addPopupMenuWithName:@"Mosaic Shape"
	                              parameterID:kParamID_MosaicShape
	                             defaultValue:0
	                              menuEntries:@[@"Square", @"Triangle", @"Hexagon"]
	                           parameterFlags:kFxParameterFlag_DEFAULT];

	ok = ok && [paramAPI addPercentSliderWithName:@"Cell Noise"
	                                  parameterID:kParamID_CellNoise
	                                 defaultValue:CELL_NOISE_DFLT / 100.0
	                                 parameterMin:CELL_NOISE_MIN / 100.0
	                                 parameterMax:CELL_NOISE_MAX / 100.0
	                                    sliderMin:CELL_NOISE_MIN / 100.0
	                                    sliderMax:CELL_NOISE_MAX / 100.0
	                                        delta:0.001
	                               parameterFlags:kFxParameterFlag_DEFAULT];

	ok = ok && [paramAPI addPercentSliderWithName:@"Colour Noise"
	                                  parameterID:kParamID_ColorNoise
	                                 defaultValue:COLOR_NOISE_DFLT / 100.0
	                                 parameterMin:COLOR_NOISE_MIN / 100.0
	                                 parameterMax:COLOR_NOISE_MAX / 100.0
	                                    sliderMin:COLOR_NOISE_MIN / 100.0
	                                    sliderMax:COLOR_NOISE_MAX / 100.0
	                                        delta:0.001
	                               parameterFlags:kFxParameterFlag_DEFAULT];

	ok = ok && [paramAPI addToggleButtonWithName:@"Blur After Mosaic"
	                                 parameterID:kParamID_BlurAfterMosaic
	                                defaultValue:NO
	                              parameterFlags:kFxParameterFlag_DEFAULT];

	ok = ok && [paramAPI addPercentSliderWithName:@"Desaturate"
	                                  parameterID:kParamID_Desaturate
	                                 defaultValue:DESATURATE_DFLT / 100.0
	                                 parameterMin:0.0
	                                 parameterMax:1.0
	                                    sliderMin:0.0
	                                    sliderMax:1.0
	                                        delta:0.01
	                               parameterFlags:kFxParameterFlag_DEFAULT];

	if (!ok && error != NULL)
		*error = [NSError errorWithDomain:FxPlugErrorDomain
		                             code:kFxError_InvalidParameter
		                         userInfo:@{ NSLocalizedDescriptionKey :
		                             @"Unable to add Anonymizer parameters" }];
	return ok;
}

// Push-button callback for "Randomize Seed".
- (void)randomizeSeed
{
	id<FxParameterSettingAPI_v5> settingAPI =
		[_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
	if (settingAPI == nil)
		return;
	id<FxCustomParameterActionAPI_v4> actionAPI =
		[_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
	[actionAPI startAction:self];
	[settingAPI setIntValue:AnonAlgo::RandomSeedValue()
	            toParameter:kParamID_Seed
	                 atTime:kCMTimeZero];
	[actionAPI endAction:self];
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
	BOOL blurAfterMosaicState = NO;
	BOOL sessionKeyState = YES;
	int seedValue = 0;
	[paramAPI getFloatValue:&state.distortAmount fromParameter:kParamID_DistortAmount atTime:renderTime];
	[paramAPI getFloatValue:&state.distortScale fromParameter:kParamID_DistortScale atTime:renderTime];
	[paramAPI getFloatValue:&state.blurRadius fromParameter:kParamID_BlurRadius atTime:renderTime];
	[paramAPI getFloatValue:&state.mosaicSize fromParameter:kParamID_MosaicSize atTime:renderTime];
	[paramAPI getIntValue:&seedValue fromParameter:kParamID_Seed atTime:renderTime];
	[paramAPI getBoolValue:&jitterState fromParameter:kParamID_TemporalJitter atTime:renderTime];
	[paramAPI getBoolValue:&blackoutState fromParameter:kParamID_Blackout atTime:renderTime];
	[paramAPI getBoolValue:&sessionKeyState fromParameter:kParamID_SessionKey atTime:renderTime];
	double desaturate = 0.0;
	[paramAPI getFloatValue:&desaturate fromParameter:kParamID_Desaturate atTime:renderTime];
	state.desaturate = desaturate * 100.0;
	double cellNoise = 0.0;
	[paramAPI getFloatValue:&cellNoise fromParameter:kParamID_CellNoise atTime:renderTime];
	state.cellNoise = cellNoise * 100.0;
	double colorNoise = 0.0;
	[paramAPI getFloatValue:&colorNoise fromParameter:kParamID_ColorNoise atTime:renderTime];
	state.colorNoise = colorNoise * 100.0;
	BOOL enableDistort = YES, enableBlur = YES, enableMosaic = YES;
	[paramAPI getBoolValue:&enableDistort fromParameter:kParamID_EnableDistort atTime:renderTime];
	[paramAPI getBoolValue:&enableBlur fromParameter:kParamID_EnableBlur atTime:renderTime];
	[paramAPI getBoolValue:&enableMosaic fromParameter:kParamID_EnableMosaic atTime:renderTime];
	state.enableDistort = enableDistort ? 1 : 0;
	state.enableBlur = enableBlur ? 1 : 0;
	state.enableMosaic = enableMosaic ? 1 : 0;
	state.blackout = blackoutState ? 1 : 0;
	[paramAPI getBoolValue:&blurAfterMosaicState fromParameter:kParamID_BlurAfterMosaic atTime:renderTime];
	state.blurAfterMosaic = blurAfterMosaicState ? 1 : 0;
	int shapeValue = 0;
	[paramAPI getIntValue:&shapeValue fromParameter:kParamID_MosaicShape atTime:renderTime];
	state.mosaicShape = (shapeValue >= 0 && shapeValue <= 2) ? shapeValue : 0;

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
	// pluginState and the render run in the same service process, so they
	// see the same session key.
	state.seed = AnonComputeSeed((double)seedValue, jitterState, frame,
		sessionKeyState ? AnonAlgo::SessionKey() : 0u);

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

	// Pixel-space parameters are relative to 1080p; the shorter frame
	// dimension reflects proxy/preview scaling and is orientation-invariant
	// (portrait vs landscape timelines).
	const float ds = AnonResolutionScale(width, height);

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

	// __block: dispatchPass below must see later changes (mBlurDir); a plain
	// capture would freeze the values at block creation.
	__block AnonParamsHost params = {};
	params.mSrcPitch = width;
	params.mDstPitch = width;
	params.m16f = 0;
	params.mWidth = width;
	params.mHeight = height;
	const float blurRadius = AnonAlgo::LayerStrength(state.blurRadius, BLUR_RADIUS_MIN,
		state.enableBlur != 0, ds, 0.0f);
	params.mBlurRadius = (int)fminf(ceilf(blurRadius), 512.0f);
	params.mBlurDir = 0;
	params.mDistortAmount = AnonAlgo::LayerStrength(state.distortAmount, DISTORT_AMOUNT_MIN,
		state.enableDistort != 0, ds, 0.0f);
	params.mDistortScale = fmaxf((float)state.distortScale * ds, 2.0f);
	params.mBlurSigma = fmaxf(blurRadius * 0.5f, 0.1f);
	// 1 px blocks disable the mosaic pass (and with it the cell/colour noise).
	params.mMosaicSize = AnonAlgo::LayerStrength(state.mosaicSize, MOSAIC_SIZE_MIN,
		state.enableMosaic != 0, ds, 1.0f);
	params.mMosaicShape = state.mosaicShape;
	params.mSeed = state.seed;
	AnonAlgo::DisplacementBias(width, height, params.mDistortScale, params.mSeed,
		&params.mDistortBiasDx, &params.mDistortBiasDy);
	params.mDesaturate = (float)(state.desaturate / 100.0);
	params.mCellNoise = (float)(state.cellNoise / 100.0);
	params.mColorNoise = (float)(state.colorNoise / 100.0);
	params.mChannelOrder = ANON_ORDER_RGBA; // texture reads are always RGBA

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
		if (state.blurAfterMosaic && params.mBlurRadius >= 1)
		{
			dispatchPass(cache.psoMosaic, bufA, bufB);
			params.mBlurDir = 0;
			dispatchPass(cache.psoBlur, bufB, bufA);
			params.mBlurDir = 1;
			dispatchPass(cache.psoBlur, bufA, bufB);
		}
		else
		{
			if (params.mBlurRadius >= 1)
			{
				params.mBlurDir = 0;
				dispatchPass(cache.psoBlur, bufA, bufB);
				params.mBlurDir = 1;
				dispatchPass(cache.psoBlur, bufB, bufA);
			}
			dispatchPass(cache.psoMosaic, bufA, bufB);
		}
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
