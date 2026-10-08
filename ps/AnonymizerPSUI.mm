/*
** Multi-Layer Anonymizer - Photoshop filter plugin (Cocoa dialog).
**
** Programmatic modal dialog, no xib: a live preview over four slider rows
** matching the NLE parameters, a mosaic-shape popup and a blackout
** checkbox. The preview reruns the shared pass pipeline on the proxy
** buffer on every control change - the proxy is small enough that this is
** interactive.
*/

#include "AnonymizerPS.h"

#include "AnonymizerAlgo.h"

#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <string.h>
#include <vector>

#define ANON_STR_(x) #x
#define ANON_STR(x) ANON_STR_(x)

@class AnonDialogController;

/* One slider row: label, slider, editable value field kept in sync. */
@interface AnonSliderRow : NSObject
{
@public
	NSSlider* slider;
	NSTextField* field;
	__weak AnonDialogController* controller;
}
- (double)value;
@end

@interface AnonDialogController : NSObject
{
@public
	AnonSliderRow* amount;
	AnonSliderRow* scale;
	AnonSliderRow* blur;
	AnonSliderRow* mosaic;
	NSPopUpButton* shape;
	NSButton* blackout;
	NSButton* blurAfterMosaic;
	NSImageView* previewView;
	PSPreviewContext preview; /* pixels == NULL when there is no preview */
	std::vector<float> work;
	std::vector<float> scratch;
}
- (void)refreshPreview;
@end

@implementation AnonSliderRow
- (void)sliderMoved:(id)sender
{
	[field setStringValue:[NSString stringWithFormat:@"%.1f", slider.doubleValue]];
	[controller refreshPreview];
}
- (void)fieldEdited:(id)sender
{
	[controller refreshPreview];
}
- (double)value
{
	/* The field is authoritative so typed values win; clamp to the slider range. */
	double v = [field doubleValue];
	if (v < slider.minValue) v = slider.minValue;
	if (v > slider.maxValue) v = slider.maxValue;
	return v;
}
- (void)setValue:(double)v
{
	slider.doubleValue = v;
	[field setStringValue:[NSString stringWithFormat:@"%.1f", v]];
}
@end

@implementation AnonDialogController

- (void)controlChanged:(id)sender
{
	if (sender == blurAfterMosaic)
		[blur setValue:AnonAlgo::BlurRadiusForOrderChange([blur value],
			blurAfterMosaic.state == NSControlStateValueOn)];
	[self refreshPreview];
}

- (void)resetPressed:(id)sender
{
	[amount setValue:DISTORT_AMOUNT_DFLT];
	[scale setValue:DISTORT_SCALE_DFLT];
	[blur setValue:BLUR_RADIUS_DFLT];
	[mosaic setValue:MOSAIC_SIZE_DFLT];
	[shape selectItemAtIndex:ANON_SHAPE_SQUARE];
	blackout.state = NSControlStateValueOff;
	blurAfterMosaic.state = NSControlStateValueOff;
	[self refreshPreview];
}

- (PSParameters)readParameters
{
	PSParameters p = {};
	p.distortAmount = [amount value];
	p.distortScale = [scale value];
	p.blurRadius = [blur value];
	p.mosaicSize = [mosaic value];
	p.mosaicShape = (int32)[shape indexOfSelectedItem];
	p.blackout = blackout.state == NSControlStateValueOn;
	p.blurAfterMosaic = blurAfterMosaic.state == NSControlStateValueOn;
	return p;
}

- (void)refreshPreview
{
	if (preview.pixels == NULL)
		return;

	const int pw = preview.width;
	const int ph = preview.height;
	const size_t n = (size_t)pw * ph * 4;
	memcpy(work.data(), preview.pixels, n * sizeof(float));

	const PSParameters p = [self readParameters];
	if (p.blackout)
	{
		for (size_t i = 0; i < (size_t)pw * ph; ++i)
			for (int c = 0; c < preview.colorPlanes; ++c)
				work[i * 4 + c] = 0.0f;
	}
	else
	{
		const float ds = preview.ds;
		int shapeIdx = (int)p.mosaicShape;
		if (shapeIdx < ANON_SHAPE_SQUARE || shapeIdx > ANON_SHAPE_HEXAGON)
			shapeIdx = ANON_SHAPE_SQUARE;
		AnonAlgo::RunLayeredPasses(work.data(), scratch.data(), pw, ph,
			(float)p.distortAmount * ds,
			std::max((float)p.distortScale * ds, 2.0f),
			std::min((float)p.blurRadius * ds, 512.0f),
			std::max((float)p.mosaicSize * ds, 1.0f),
			shapeIdx, 0u, p.blurAfterMosaic != 0);
	}

	NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:NULL
		pixelsWide:pw
		pixelsHigh:ph
		bitsPerSample:8
		samplesPerPixel:3
		hasAlpha:NO
		isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace
		bytesPerRow:pw * 3
		bitsPerPixel:24];
	if (rep == nil)
		return;

	uint8_t* dst = rep.bitmapData;
	const bool gray = preview.colorPlanes == 1;
	for (size_t i = 0; i < (size_t)pw * ph; ++i)
	{
		for (int c = 0; c < 3; ++c)
		{
			float v = work[i * 4 + (gray ? 0 : c)];
			if (v < 0.0f) v = 0.0f;
			if (v > 1.0f) v = 1.0f;
			dst[i * 3 + c] = (uint8_t)(v * 255.0f + 0.5f);
		}
	}

	NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(pw, ph)];
	[image addRepresentation:rep];
	previewView.image = image;
}

@end

static AnonSliderRow* AddSliderRow(NSView* content, AnonDialogController* controller,
	CGFloat y, NSString* label, double minV, double maxV, double value)
{
	NSTextField* name = [NSTextField labelWithString:label];
	name.frame = NSMakeRect(16, y, 150, 20);
	name.alignment = NSTextAlignmentRight;
	[content addSubview:name];

	AnonSliderRow* row = [[AnonSliderRow alloc] init];
	row->controller = controller;

	row->slider = [[NSSlider alloc] initWithFrame:NSMakeRect(176, y - 1, 190, 22)];
	row->slider.minValue = minV;
	row->slider.maxValue = maxV;
	row->slider.doubleValue = value;
	row->slider.continuous = YES;
	row->slider.target = row;
	row->slider.action = @selector(sliderMoved:);
	[content addSubview:row->slider];

	row->field = [[NSTextField alloc] initWithFrame:NSMakeRect(376, y - 2, 60, 22)];
	[row->field setStringValue:[NSString stringWithFormat:@"%.1f", value]];
	row->field.target = row;
	row->field.action = @selector(fieldEdited:);
	[content addSubview:row->field];

	return row;
}

bool DoParamDialog(PSParameters* ioParams, const PSPreviewContext* previewIn)
{
	@autoreleasepool
	{
		const bool hasPreview = previewIn != NULL && previewIn->pixels != NULL;
		const CGFloat kControlsHeight = 300;
		const CGFloat kPreviewHeight = hasPreview ? 300 : 0;

		NSWindow* window = [[NSWindow alloc]
			initWithContentRect:NSMakeRect(0, 0, 452, kControlsHeight + kPreviewHeight)
			styleMask:NSWindowStyleMaskTitled
			backing:NSBackingStoreBuffered
			defer:NO];
		window.title = @ANONYMIZER_NAME;
		window.releasedWhenClosed = NO;
		NSView* content = window.contentView;

		AnonDialogController* controller = [[AnonDialogController alloc] init];
		if (hasPreview)
		{
			controller->preview = *previewIn;
			const size_t n = (size_t)previewIn->width * previewIn->height * 4;
			controller->work.resize(n);
			controller->scratch.resize(n);

			controller->previewView = [[NSImageView alloc]
				initWithFrame:NSMakeRect(16, kControlsHeight + 4,
					452 - 32, kPreviewHeight - 12)];
			controller->previewView.imageScaling = NSImageScaleProportionallyDown;
			controller->previewView.imageAlignment = NSImageAlignCenter;
			[content addSubview:controller->previewView];
		}
		else
		{
			controller->preview.pixels = NULL;
		}

		controller->amount = AddSliderRow(content, controller, 256, @"Distortion Amount:",
			DISTORT_AMOUNT_MIN, DISTORT_AMOUNT_MAX, ioParams->distortAmount);
		controller->scale = AddSliderRow(content, controller, 224, @"Distortion Scale:",
			DISTORT_SCALE_MIN, DISTORT_SCALE_MAX, ioParams->distortScale);
		controller->blur = AddSliderRow(content, controller, 192, @"Blur Radius:",
			BLUR_RADIUS_MIN, BLUR_RADIUS_MAX, ioParams->blurRadius);
		controller->mosaic = AddSliderRow(content, controller, 160, @"Mosaic Size:",
			MOSAIC_SIZE_MIN, MOSAIC_SIZE_MAX, ioParams->mosaicSize);

		NSTextField* shapeLabel = [NSTextField labelWithString:@"Mosaic Shape:"];
		shapeLabel.frame = NSMakeRect(16, 126, 150, 20);
		shapeLabel.alignment = NSTextAlignmentRight;
		[content addSubview:shapeLabel];

		controller->shape = [[NSPopUpButton alloc]
			initWithFrame:NSMakeRect(174, 122, 150, 26) pullsDown:NO];
		[controller->shape addItemsWithTitles:@[ @"Square", @"Triangle", @"Hexagon" ]];
		[controller->shape selectItemAtIndex:
			(ioParams->mosaicShape >= 0 && ioParams->mosaicShape <= 2)
				? ioParams->mosaicShape : 0];
		controller->shape.target = controller;
		controller->shape.action = @selector(controlChanged:);
		[content addSubview:controller->shape];

		controller->blurAfterMosaic = [NSButton
			checkboxWithTitle:@"Blur After Mosaic"
			target:controller action:@selector(controlChanged:)];
		controller->blurAfterMosaic.frame = NSMakeRect(176, 92, 264, 20);
		controller->blurAfterMosaic.toolTip = @"Apply blur after mosaic to soften the visible cell edges";
		controller->blurAfterMosaic.state = ioParams->blurAfterMosaic ? NSControlStateValueOn
			: NSControlStateValueOff;
		[content addSubview:controller->blurAfterMosaic];

		controller->blackout = [NSButton
			checkboxWithTitle:@"Blackout (solid black instead of the layered passes)"
			target:controller action:@selector(controlChanged:)];
		controller->blackout.frame = NSMakeRect(176, 60, 264, 20);
		controller->blackout.state = ioParams->blackout ? NSControlStateValueOn
														: NSControlStateValueOff;
		[content addSubview:controller->blackout];

		NSButton* reset = [NSButton buttonWithTitle:@"Reset to Defaults"
			target:controller action:@selector(resetPressed:)];
		reset.frame = NSMakeRect(16, 14, 140, 30);
		[content addSubview:reset];

		NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:nil action:nil];
		cancel.frame = NSMakeRect(256, 14, 88, 30);
		cancel.keyEquivalent = @"\033";
		cancel.target = NSApp;
		cancel.action = @selector(abortModal);
		[content addSubview:cancel];

		NSButton* ok = [NSButton buttonWithTitle:@"OK" target:nil action:nil];
		ok.frame = NSMakeRect(348, 14, 88, 30);
		ok.keyEquivalent = @"\r";
		ok.target = NSApp;
		ok.action = @selector(stopModal);
		[content addSubview:ok];

		[controller refreshPreview];

		[window center];
		[window makeKeyAndOrderFront:nil];
		NSModalResponse response = [NSApp runModalForWindow:window];
		[window orderOut:nil];

		if (response != NSModalResponseStop)
			return false;

		*ioParams = [controller readParameters];
		return true;
	}
}

void DoAboutDialog(void)
{
	@autoreleasepool
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = @ANONYMIZER_NAME;
		alert.informativeText =
			@"Version " ANON_STR(MAJOR_VERSION) "." ANON_STR(MINOR_VERSION)
			"." ANON_STR(BUG_VERSION) "\n\n"
			 "Anonymizes a region with three stacked layers - random "
			 "distortion, Gaussian blur and mosaic - so the result cannot be "
			 "reversed by deblurring or mosaic-reconstruction tools.";
		[alert addButtonWithTitle:@"OK"];
		[alert runModal];
	}
}
