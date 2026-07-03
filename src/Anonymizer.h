/*
** Multi-Layer Anonymizer for Adobe Premiere Pro
**
** A single effect that stacks three obfuscation layers so the result can not
** be undone by deconvolution / mosaic-reversal tools:
**
**   Layer 1: pseudo-random spatial distortion (value-noise displacement)
**   Layer 2: Gaussian blur
**   Layer 3: mosaic (pixelation)
**
** Shared declarations for the CPU (software) and GPU (Metal) render paths.
*/

#ifndef ANONYMIZER_H
#define ANONYMIZER_H

#include "AEConfig.h"
#include "PrSDKTypes.h"
#include "AE_Effect.h"
#include "A.h"
#include "AE_Macros.h"
#include "Param_Utils.h"
#include "AEFX_SuiteHandlerTemplate.h"
#include "PrSDKAESupport.h"

#include "AnonymizerAlgo.h"

/*
** Effect identity. ANONYMIZER_MATCH_NAME must stay in sync with
** AE_Effect_Match_Name in Anonymizer.r. The GPU filter entry point in the
** same binary is bound to this PiPL automatically (PrGPUFilterInfo with a
** null match name defaults to the module's PiPL).
*/
/* Normally injected by CMake (edition branding); these are the OSS defaults. */
#ifndef ANONYMIZER_NAME
#define ANONYMIZER_NAME       "Multi-Layer Anonymizer"
#endif
#ifndef ANONYMIZER_MATCH_NAME
#define ANONYMIZER_MATCH_NAME "AGDL Multi-Layer Anonymizer"
#endif
#ifndef ANONYMIZER_CATEGORY
#define ANONYMIZER_CATEGORY   "Aagedal"
#endif

/*
** Parameter indices, shared by the CPU parameter definitions and the GPU
** GetParam() calls (the GPU side subtracts 1 for the input layer itself).
*/
enum
{
	ANON_INPUT = 0,
	ANON_DISTORT_AMOUNT,
	ANON_DISTORT_SCALE,
	ANON_BLUR_RADIUS,
	ANON_MOSAIC_SIZE,
	ANON_SEED,
	ANON_TEMPORAL_JITTER,
	ANON_BLACKOUT,
	ANON_MOSAIC_SHAPE,
	ANON_NUM_PARAMS
};

// MAJOR_VERSION, MINOR_VERSION, BUG_VERSION injected by CMake (project VERSION).
#define	STAGE_VERSION   PF_Stage_DEVELOP
#define	BUILD_VERSION   0

/*
** Global out_flags. The value must match AE_Effect_Global_OutFlags in
** Anonymizer.r (0x00000004). NON_PARAM_VARY: with temporal jitter enabled the
** output varies with time even when no parameter is keyframed.
*/
#define ANONYMIZER_OUT_FLAGS  (PF_OutFlag_NON_PARAM_VARY)
#define ANONYMIZER_OUT_FLAGS2 (0)

#endif // ANONYMIZER_H
