/*
** Multi-Layer Anonymizer FxPlug - wrapper application.
**
** The app carries the FxPlug XPC service in Contents/PlugIns; launching it
** once registers the plugin with PluginKit. It also installs the bundled
** Motion templates into ~/Movies/Motion Templates.localized - Final Cut Pro
** only shows FxPlug effects through a Motion template, and templates can
** only live in the user's home folder, so the app (running as the user)
** installs them rather than the installer package (running as root).
** The sandbox reaches the real ~/Movies via the
** com.apple.security.assets.movies.read-write entitlement.
*/

#import <Cocoa/Cocoa.h>

#ifndef ANON_EFFECT_NAME
#define ANON_EFFECT_NAME "Multi-Layer Anonymizer"
#endif
#ifndef ANON_CATEGORY
#define ANON_CATEGORY "Aagedal"
#endif

/*
** Copies Contents/Resources/Motion Templates/Effects/<Category>/<Template>
** into ~/Movies/Motion Templates.localized/Effects.localized/, replacing any
** existing copy so updates take effect. Returns the number of templates
** installed, or -1 on error.
*/
static NSInteger InstallMotionTemplates(NSError** outError)
{
	NSFileManager* fm = [NSFileManager defaultManager];
	NSString* srcEffects = [[[NSBundle mainBundle] resourcePath]
		stringByAppendingPathComponent:@"Motion Templates/Effects"];
	if (![fm fileExistsAtPath:srcEffects])
		return 0; // no templates bundled

	NSString* dstEffects = [NSHomeDirectory() stringByAppendingPathComponent:
		@"Movies/Motion Templates.localized/Effects.localized"];

	NSInteger installed = 0;
	for (NSString* category in [fm contentsOfDirectoryAtPath:srcEffects error:NULL])
	{
		NSString* srcCategory = [srcEffects stringByAppendingPathComponent:category];
		BOOL isDir = NO;
		if (![fm fileExistsAtPath:srcCategory isDirectory:&isDir] || !isDir)
			continue;

		NSString* dstCategory = [dstEffects stringByAppendingPathComponent:category];
		if (![fm createDirectoryAtPath:dstCategory
		   withIntermediateDirectories:YES
		                    attributes:nil
		                         error:outError])
			return -1;

		for (NSString* template_ in [fm contentsOfDirectoryAtPath:srcCategory error:NULL])
		{
			NSString* srcTemplate = [srcCategory stringByAppendingPathComponent:template_];
			NSString* dstTemplate = [dstCategory stringByAppendingPathComponent:template_];
			if ([fm fileExistsAtPath:dstTemplate])
				[fm removeItemAtPath:dstTemplate error:NULL];
			if (![fm copyItemAtPath:srcTemplate toPath:dstTemplate error:outError])
				return -1;
			++installed;
		}
	}
	return installed;
}

int main(int argc, const char* argv[])
{
	@autoreleasepool
	{
		[NSApplication sharedApplication];

		NSError* error = nil;
		NSInteger templates = InstallMotionTemplates(&error);

		NSAlert* alert = [[NSAlert alloc] init];
		if (templates < 0)
		{
			alert.messageText = @ANON_EFFECT_NAME ": template installation failed";
			alert.informativeText = [NSString stringWithFormat:
				@"The FxPlug plugin was registered, but the Final Cut Pro "
				@"template could not be installed:\n%@",
				error.localizedDescription];
		}
		else
		{
			alert.messageText = @ANON_EFFECT_NAME " installed";
			alert.informativeText = @"The effect has been registered and its "
				@"Final Cut Pro template installed. Restart Final Cut Pro and "
				@"look for \"" ANON_EFFECT_NAME "\" in the Effects browser "
				@"under the " ANON_CATEGORY " category.";
		}
		[alert addButtonWithTitle:@"OK"];
		[alert runModal];
	}
	return 0;
}
