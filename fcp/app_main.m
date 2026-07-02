/*
** Multi-Layer Anonymizer FxPlug - wrapper application.
**
** The app exists only to carry the FxPlug XPC service in Contents/PlugIns;
** launching it once registers the plugin with PluginKit so Final Cut Pro
** and Motion can find it.
*/

#import <Cocoa/Cocoa.h>

#ifndef ANON_EFFECT_NAME
#define ANON_EFFECT_NAME "Multi-Layer Anonymizer"
#endif
#ifndef ANON_CATEGORY
#define ANON_CATEGORY "Aagedal"
#endif

int main(int argc, const char* argv[])
{
	@autoreleasepool
	{
		[NSApplication sharedApplication];
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = @ANON_EFFECT_NAME " registered";
		alert.informativeText = @"The FxPlug effect has been registered with the system. "
			@"Restart Final Cut Pro or Motion and look for \"" ANON_EFFECT_NAME "\" "
			@"in the Effects browser under the " ANON_CATEGORY " category.";
		[alert addButtonWithTitle:@"OK"];
		[alert runModal];
	}
	return 0;
}
