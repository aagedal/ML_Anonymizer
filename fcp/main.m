/*
** Multi-Layer Anonymizer FxPlug - XPC service entry point.
*/

#import <FxPlug/FxPlugSDK.h>

int main(int argc, const char* argv[])
{
	[FxPrincipal startServicePrincipal];
}
