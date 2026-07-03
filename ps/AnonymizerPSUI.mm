/*
** Multi-Layer Anonymizer - Photoshop filter plugin (Cocoa dialog).
**
** Programmatic modal dialog, no xib: four slider rows matching the NLE
** parameters, a mosaic-shape popup and a blackout checkbox. Runs inside
** Photoshop's process via runModalForWindow, like the SDK samples.
*/

#include "AnonymizerPS.h"

#include "AnonymizerAlgo.h"

#import <Cocoa/Cocoa.h>

#define ANON_STR_(x) #x
#define ANON_STR(x) ANON_STR_(x)

/* One slider row: label, slider, editable value field kept in sync. */
@interface AnonSliderRow : NSObject
{
@public
	NSSlider* slider;
	NSTextField* field;
}
- (double)value;
@end

@implementation AnonSliderRow
- (void)sliderMoved:(id)sender
{
	[field setStringValue:[NSString stringWithFormat:@"%.1f", slider.doubleValue]];
}
- (double)value
{
	/* The field is authoritative so typed values win; clamp to the slider range. */
	double v = [field doubleValue];
	if (v < slider.minValue) v = slider.minValue;
	if (v > slider.maxValue) v = slider.maxValue;
	return v;
}
@end

static AnonSliderRow* AddSliderRow(NSView* content, CGFloat y,
	NSString* label, double minV, double maxV, double value)
{
	NSTextField* name = [NSTextField labelWithString:label];
	name.frame = NSMakeRect(16, y, 150, 20);
	name.alignment = NSTextAlignmentRight;
	[content addSubview:name];

	AnonSliderRow* row = [[AnonSliderRow alloc] init];

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
	[content addSubview:row->field];

	return row;
}

bool DoParamDialog(PSParameters* ioParams)
{
	@autoreleasepool
	{
		NSWindow* window = [[NSWindow alloc]
			initWithContentRect:NSMakeRect(0, 0, 452, 268)
			styleMask:NSWindowStyleMaskTitled
			backing:NSBackingStoreBuffered
			defer:NO];
		window.title = @ANONYMIZER_NAME;
		window.releasedWhenClosed = NO;
		NSView* content = window.contentView;

		AnonSliderRow* amount = AddSliderRow(content, 224, @"Distortion Amount:",
			DISTORT_AMOUNT_MIN, DISTORT_AMOUNT_MAX, ioParams->distortAmount);
		AnonSliderRow* scale = AddSliderRow(content, 192, @"Distortion Scale:",
			DISTORT_SCALE_MIN, DISTORT_SCALE_MAX, ioParams->distortScale);
		AnonSliderRow* blur = AddSliderRow(content, 160, @"Blur Radius:",
			BLUR_RADIUS_MIN, BLUR_RADIUS_MAX, ioParams->blurRadius);
		AnonSliderRow* mosaic = AddSliderRow(content, 128, @"Mosaic Size:",
			MOSAIC_SIZE_MIN, MOSAIC_SIZE_MAX, ioParams->mosaicSize);

		NSTextField* shapeLabel = [NSTextField labelWithString:@"Mosaic Shape:"];
		shapeLabel.frame = NSMakeRect(16, 94, 150, 20);
		shapeLabel.alignment = NSTextAlignmentRight;
		[content addSubview:shapeLabel];

		NSPopUpButton* shape = [[NSPopUpButton alloc]
			initWithFrame:NSMakeRect(174, 90, 150, 26) pullsDown:NO];
		[shape addItemsWithTitles:@[ @"Square", @"Triangle", @"Hexagon" ]];
		[shape selectItemAtIndex:
			(ioParams->mosaicShape >= 0 && ioParams->mosaicShape <= 2)
				? ioParams->mosaicShape : 0];
		[content addSubview:shape];

		NSButton* blackout = [NSButton
			checkboxWithTitle:@"Blackout (solid black instead of the layered passes)"
			target:nil action:nil];
		blackout.frame = NSMakeRect(176, 60, 264, 20);
		blackout.state = ioParams->blackout ? NSControlStateValueOn
											: NSControlStateValueOff;
		[content addSubview:blackout];

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

		[window center];
		[window makeKeyAndOrderFront:nil];
		NSModalResponse response = [NSApp runModalForWindow:window];
		[window orderOut:nil];

		if (response != NSModalResponseStop)
			return false;

		ioParams->distortAmount = [amount value];
		ioParams->distortScale = [scale value];
		ioParams->blurRadius = [blur value];
		ioParams->mosaicSize = [mosaic value];
		ioParams->mosaicShape = (int32)[shape indexOfSelectedItem];
		ioParams->blackout = blackout.state == NSControlStateValueOn;
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
