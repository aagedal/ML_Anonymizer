/*
** Multi-Layer Anonymizer - Photoshop filter plugin.
**
** Shared declarations between the filter logic (AnonymizerPS.cpp) and the
** Cocoa parameter dialog (AnonymizerPSUI.mm). The pixel pipeline itself
** lives in shared/AnonymizerAlgo.h and is byte-identical to the CPU path
** of the Premiere / Resolve / FCP plugins.
*/

#ifndef ANONYMIZER_PS_H
#define ANONYMIZER_PS_H

#include "PIDefines.h"
#include "PITypes.h"
#include "PIAbout.h"
#include "PIFilter.h"

#ifndef ANONYMIZER_NAME
#define ANONYMIZER_NAME "Multi-Layer Anonymizer"
#endif

/*
** Persisted in the host-owned parameters handle, so "Last Filter" (Cmd-F)
** reruns with the previous values. Fixed-size scalar fields only.
*/
typedef struct PSParameters
{
	double distortAmount;
	double distortScale;
	double blurRadius;
	double mosaicSize;
	int32 mosaicShape; /* ANON_SHAPE_* */
	Boolean blackout;
} PSParameters;

/*
** Implemented in AnonymizerPSUI.mm. Returns true if the user confirmed.
** The dialog edits ioParams in place; the caller restores on cancel.
*/
bool DoParamDialog(PSParameters* ioParams);
void DoAboutDialog(void);

#endif
