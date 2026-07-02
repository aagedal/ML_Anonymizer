/*
** Multi-Layer Anonymizer - FxPlug 4 plugin for Final Cut Pro / Motion.
*/

#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>

@interface AnonymizerFxPlugIn : NSObject <FxTileableEffect>
@property (assign) id<PROAPIAccessing> apiManager;
@end
