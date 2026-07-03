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
** Downscaled copy of the filtered region for the dialog's live preview.
** pixels is packed RGBA float (pitch == width); ds is the resolution scale
** the preview passes must use so the proxy approximates the full-res
** result; colorPlanes is 1 for grayscale documents, else 3.
*/
typedef struct PSPreviewContext
{
	const float* pixels;
	int width;
	int height;
	float ds;
	int colorPlanes;
} PSPreviewContext;

/*
** Implemented in AnonymizerPSUI.mm. Returns true if the user confirmed.
** The dialog edits ioParams in place; the caller restores on cancel.
** preview may be NULL (or have NULL pixels) - the dialog then runs
** without the live preview.
*/
bool DoParamDialog(PSParameters* ioParams, const PSPreviewContext* preview);
void DoAboutDialog(void);

#endif
