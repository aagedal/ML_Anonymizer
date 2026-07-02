/*
** Multi-Layer Anonymizer FxPlug - per-device Metal pipeline cache.
**
** Compiles the shared kernel source (plus the FxPlug-specific copy-in and
** output shaders) once per Metal device, and caches compute/render pipeline
** states. Thread-safe: FCP calls render on multiple threads concurrently.
*/

#import "AnonMetalCache.h"

#include "AnonymizerKernel.h"
#include "FxPlugExtraKernels.h"

@implementation AnonMetalCacheEntry
{
	NSMutableDictionary<NSNumber*, id<MTLRenderPipelineState>>* _renderPipelines;
	id<MTLLibrary> _library;
	NSLock* _lock;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
	self = [super init];
	if (self == nil)
		return nil;

	_lock = [[NSLock alloc] init];
	_renderPipelines = [NSMutableDictionary dictionary];
	self.device = device;
	self.queue = [device newCommandQueue];

	NSString* source = [NSString stringWithFormat:@"%s\n%s",
		kAnonymizerMetalString, kAnonymizerFxPlugExtraMetal];
	NSError* error = nil;
	// Precise math so cell/pixel selection matches the other hosts exactly.
	MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
	options.fastMathEnabled = NO;
	_library = [device newLibraryWithSource:source options:options error:&error];
	if (_library == nil)
	{
		NSLog(@"Anonymizer FxPlug: Metal library compile failed: %@", error);
		return nil;
	}

	self.psoCopyIn = [self computePipeline:@"AnonCopyIn"];
	self.psoDistort = [self computePipeline:@"AnonDistort"];
	self.psoBlur = [self computePipeline:@"AnonBlur"];
	self.psoMosaic = [self computePipeline:@"AnonMosaic"];
	self.psoBlackout = [self computePipeline:@"AnonBlackout"];
	if (!self.psoCopyIn || !self.psoDistort || !self.psoBlur || !self.psoMosaic || !self.psoBlackout)
		return nil;

	return self;
}

- (id<MTLComputePipelineState>)computePipeline:(NSString*)name
{
	id<MTLFunction> function = [_library newFunctionWithName:name];
	if (function == nil)
		return nil;
	NSError* error = nil;
	id<MTLComputePipelineState> pso = [self.device newComputePipelineStateWithFunction:function error:&error];
	if (pso == nil)
		NSLog(@"Anonymizer FxPlug: pipeline %@ failed: %@", name, error);
	return pso;
}

- (id<MTLRenderPipelineState>)renderPipelineForPixelFormat:(MTLPixelFormat)format
{
	[_lock lock];
	id<MTLRenderPipelineState> pso = _renderPipelines[@(format)];
	if (pso == nil)
	{
		MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
		desc.vertexFunction = [_library newFunctionWithName:@"AnonVertex"];
		desc.fragmentFunction = [_library newFunctionWithName:@"AnonFragment"];
		desc.colorAttachments[0].pixelFormat = format;
		NSError* error = nil;
		pso = [self.device newRenderPipelineStateWithDescriptor:desc error:&error];
		if (pso == nil)
			NSLog(@"Anonymizer FxPlug: render pipeline failed: %@", error);
		else
			_renderPipelines[@(format)] = pso;
	}
	[_lock unlock];
	return pso;
}

@end

@implementation AnonMetalCache
{
	NSMutableDictionary<NSNumber*, AnonMetalCacheEntry*>* _entries;
	NSLock* _lock;
}

+ (instancetype)sharedCache
{
	static AnonMetalCache* sCache = nil;
	static dispatch_once_t sOnce;
	dispatch_once(&sOnce, ^{
		sCache = [[AnonMetalCache alloc] init];
	});
	return sCache;
}

- (instancetype)init
{
	self = [super init];
	if (self != nil)
	{
		_entries = [NSMutableDictionary dictionary];
		_lock = [[NSLock alloc] init];
	}
	return self;
}

- (AnonMetalCacheEntry*)entryForDeviceRegistryID:(uint64_t)registryID
{
	[_lock lock];
	AnonMetalCacheEntry* entry = _entries[@(registryID)];
	if (entry == nil)
	{
		NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
		for (id<MTLDevice> device in devices)
		{
			if (device.registryID == registryID)
			{
				entry = [[AnonMetalCacheEntry alloc] initWithDevice:device];
				break;
			}
		}
		// Fall back to the default device if the registry ID was not found
		// (e.g. an eGPU was disconnected between calls).
		if (entry == nil)
		{
			id<MTLDevice> device = MTLCreateSystemDefaultDevice();
			if (device != nil)
				entry = [[AnonMetalCacheEntry alloc] initWithDevice:device];
		}
		if (entry != nil)
			_entries[@(registryID)] = entry;
	}
	[_lock unlock];
	return entry;
}

@end
