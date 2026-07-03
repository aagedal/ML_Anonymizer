/*
** Multi-Layer Anonymizer - Photoshop filter plugin (host glue).
**
** Selector flow follows the SDK's Dissolve sample: Parameters -> Prepare ->
** Start -> Finish, with all pixel work done from Start via advanceState().
**
** The filtered region is gathered band-by-band into one packed RGBA float
** buffer, run through the shared pass pipeline (distort -> blur -> mosaic,
** or blackout), and written back band-by-band. Photoshop itself blends the
** result through any selection mask, so maskData is never touched here.
*/

#include "AnonymizerPS.h"

#include "AnonymizerAlgo.h"

#include <algorithm>
#include <stdlib.h>
#include <string.h>
#include <vector>

FilterRecord* gFilterRecord = NULL;
int16* gResult = NULL;
PSParameters* gParams = NULL;

/*
** Session-lifetime data Photoshop hands back on every call. Photoshop calls
** filterSelectorParameters only when the filter is picked from the menu -
** not for "Last Filter" or actions - which is exactly the signal for
** whether the dialog should be shown.
*/
typedef struct SessionData
{
	Boolean queryForParameters;
} SessionData;

static SessionData* gData = NULL;

/* ---- 32-bit-safe rectangle access (big document aware) ---- */

static VRect GetFilterRect(void)
{
	if (gFilterRecord->bigDocumentData != NULL)
		return gFilterRecord->bigDocumentData->filterRect32;
	VRect r;
	r.top = gFilterRecord->filterRect.top;
	r.left = gFilterRecord->filterRect.left;
	r.bottom = gFilterRecord->filterRect.bottom;
	r.right = gFilterRecord->filterRect.right;
	return r;
}

static VPoint GetImageSize(void)
{
	if (gFilterRecord->bigDocumentData != NULL)
		return gFilterRecord->bigDocumentData->imageSize32;
	VPoint p;
	p.v = gFilterRecord->imageSize.v;
	p.h = gFilterRecord->imageSize.h;
	return p;
}

static void SetInRect(const VRect& r)
{
	if (gFilterRecord->bigDocumentData != NULL)
	{
		gFilterRecord->bigDocumentData->inRect32 = r;
	}
	else
	{
		gFilterRecord->inRect.top = (int16)r.top;
		gFilterRecord->inRect.left = (int16)r.left;
		gFilterRecord->inRect.bottom = (int16)r.bottom;
		gFilterRecord->inRect.right = (int16)r.right;
	}
}

static void SetOutRect(const VRect& r)
{
	if (gFilterRecord->bigDocumentData != NULL)
	{
		gFilterRecord->bigDocumentData->outRect32 = r;
	}
	else
	{
		gFilterRecord->outRect.top = (int16)r.top;
		gFilterRecord->outRect.left = (int16)r.left;
		gFilterRecord->outRect.bottom = (int16)r.bottom;
		gFilterRecord->outRect.right = (int16)r.right;
	}
}

static void SetMaskRect(const VRect& r)
{
	if (gFilterRecord->bigDocumentData != NULL)
	{
		gFilterRecord->bigDocumentData->maskRect32 = r;
	}
	else
	{
		gFilterRecord->maskRect.top = (int16)r.top;
		gFilterRecord->maskRect.left = (int16)r.left;
		gFilterRecord->maskRect.bottom = (int16)r.bottom;
		gFilterRecord->maskRect.right = (int16)r.right;
	}
}

/* ---- parameter / data lifetime ---- */

static void InitParameters(PSParameters* p)
{
	p->distortAmount = DISTORT_AMOUNT_DFLT;
	p->distortScale = DISTORT_SCALE_DFLT;
	p->blurRadius = BLUR_RADIUS_DFLT;
	p->mosaicSize = MOSAIC_SIZE_DFLT;
	p->mosaicShape = ANON_SHAPE_SQUARE;
	p->blackout = false;
}

static void EnsureParametersHandle(void)
{
	if (gFilterRecord->parameters != NULL)
		return;
	gFilterRecord->parameters =
		gFilterRecord->handleProcs->newProc(sizeof(PSParameters));
	if (gFilterRecord->parameters == NULL)
	{
		*gResult = memFullErr;
		return;
	}
	PSParameters* p = (PSParameters*)gFilterRecord->handleProcs->lockProc(
		gFilterRecord->parameters, TRUE);
	if (p != NULL)
	{
		InitParameters(p);
		gFilterRecord->handleProcs->unlockProc(gFilterRecord->parameters);
	}
}

static void EnsureData(void)
{
	if (gData != NULL)
		return;
	gData = (SessionData*)malloc(sizeof(SessionData));
	if (gData == NULL)
	{
		*gResult = memFullErr;
		return;
	}
	gData->queryForParameters = true;
}

static void LockParameters(void)
{
	if (gFilterRecord->parameters == NULL)
	{
		*gResult = filterBadParameters;
		return;
	}
	gParams = (PSParameters*)gFilterRecord->handleProcs->lockProc(
		gFilterRecord->parameters, TRUE);
	if (gParams == NULL)
		*gResult = memFullErr;
}

static void UnlockParameters(void)
{
	if (gFilterRecord->parameters != NULL)
		gFilterRecord->handleProcs->unlockProc(gFilterRecord->parameters);
	gParams = NULL;
}

/* ---- pixel conversion helpers ---- */

/*
** Photoshop channel ranges: 8-bit 0..255, 16-bit 0..32768 (not 65535),
** 32-bit float unclamped linear.
*/
static inline float ReadChannel(const uint8* pixel, int32 depth, int c)
{
	if (depth == 32)
		return ((const float*)pixel)[c];
	if (depth == 16)
		return (float)((const uint16*)pixel)[c] / 32768.0f;
	return (float)pixel[c] / 255.0f;
}

static inline void WriteChannel(uint8* pixel, int32 depth, int c, float v)
{
	if (depth == 32)
	{
		((float*)pixel)[c] = v;
		return;
	}
	if (v < 0.0f)
		v = 0.0f;
	if (v > 1.0f)
		v = 1.0f;
	if (depth == 16)
		((uint16*)pixel)[c] = (uint16)(v * 32768.0f + 0.5f);
	else
		pixel[c] = (uint8)(v * 255.0f + 0.5f);
}

static bool IsGrayMode(int16 mode)
{
	return mode == plugInModeGrayScale || mode == plugInModeGray16 ||
		mode == plugInModeGray32;
}

/* ---- proxy fetch for the dialog's live preview ---- */

/*
** Reads a subsampled copy of the filtered region via advanceState with a
** fixed-point inputRate, converted to packed RGBA float. Rects passed to
** the host while a rate is active are in the scaled coordinate space.
** Returns false (leaving *gResult untouched on soft failures) if no proxy
** could be produced - the dialog then simply has no preview.
*/
static bool FetchProxy(std::vector<float>& outBuf, PSPreviewContext* outCtx)
{
	const VRect filterRect = GetFilterRect();
	const int32 w = filterRect.right - filterRect.left;
	const int32 h = filterRect.bottom - filterRect.top;
	if (w <= 0 || h <= 0)
		return false;

	const int32 kMaxProxy = 560; /* fetch ~2x the view size for Retina */
	const int32 s = std::max((int32)1, (std::max(w, h) + kMaxProxy - 1) / kMaxProxy);
	const int32 pw = w / s;
	const int32 ph = h / s;
	if (pw < 1 || ph < 1)
		return false;

	const int32 depth = gFilterRecord->depth;
	const int procPlanes = std::min((int)gFilterRecord->planes, 4);
	if (procPlanes < 1)
		return false;

	outBuf.resize((size_t)pw * ph * 4);

	VRect proxyRect;
	proxyRect.left = filterRect.left / s;
	proxyRect.top = filterRect.top / s;
	proxyRect.right = proxyRect.left + pw;
	proxyRect.bottom = proxyRect.top + ph;

	const VRect zeroRect = { 0, 0, 0, 0 };
	SetOutRect(zeroRect);
	SetMaskRect(zeroRect);
	gFilterRecord->inputRate = (int32)s << 16;
	gFilterRecord->maskRate = (int32)s << 16;
	gFilterRecord->inLoPlane = 0;
	gFilterRecord->inHiPlane = (int16)(procPlanes - 1);
	SetInRect(proxyRect);

	const OSErr err = gFilterRecord->advanceState();

	bool ok = err == noErr;
	if (ok)
	{
		for (int32 y = 0; y < ph; ++y)
		{
			const uint8* row = (const uint8*)gFilterRecord->inData +
				(size_t)y * gFilterRecord->inRowBytes;
			float* out = outBuf.data() + ((size_t)y * pw) * 4;
			for (int32 x = 0; x < pw; ++x, out += 4)
			{
				const uint8* pixel = row + (size_t)x * gFilterRecord->inColumnBytes;
				out[0] = ReadChannel(pixel, depth, 0);
				out[1] = procPlanes > 1 ? ReadChannel(pixel, depth, 1) : 0.0f;
				out[2] = procPlanes > 2 ? ReadChannel(pixel, depth, 2) : 0.0f;
				out[3] = procPlanes > 3 ? ReadChannel(pixel, depth, 3) : 1.0f;
			}
		}
	}

	/* Restore full-resolution state for the real render. */
	gFilterRecord->inputRate = (int32)1 << 16;
	gFilterRecord->maskRate = (int32)1 << 16;
	SetInRect(zeroRect);

	if (!ok)
		return false;

	const VPoint imageSize = GetImageSize();
	outCtx->pixels = outBuf.data();
	outCtx->width = (int)pw;
	outCtx->height = (int)ph;
	outCtx->ds = AnonResolutionScale((int)(imageSize.h / s), (int)(imageSize.v / s));
	outCtx->colorPlanes = IsGrayMode(gFilterRecord->imageMode) ? 1 : 3;
	return true;
}

/* ---- the filter ---- */

static void DoFilterImpl(void)
{
	const VRect filterRect = GetFilterRect();
	const int32 w = filterRect.right - filterRect.left;
	const int32 h = filterRect.bottom - filterRect.top;
	if (w <= 0 || h <= 0)
		return;

	const int32 depth = gFilterRecord->depth;
	const int procPlanes = std::min((int)gFilterRecord->planes, 4);
	if (procPlanes < 1)
		return;

	/*
	** Pixel-space parameters are relative to 1080p, scaled by the document's
	** shorter dimension (not the selection), so the anonymization strength
	** is the same whether the filter runs on a selection or the whole image.
	*/
	const VPoint imageSize = GetImageSize();
	const float ds = AnonResolutionScale((int)imageSize.h, (int)imageSize.v);

	const float amount = (float)gParams->distortAmount * ds;
	const float scale = std::max((float)gParams->distortScale * ds, 2.0f);
	const float blurRadius = std::min((float)gParams->blurRadius * ds, 512.0f);
	const float mosaicSize = std::max((float)gParams->mosaicSize * ds, 1.0f);
	int mosaicShape = (int)gParams->mosaicShape;
	if (mosaicShape < ANON_SHAPE_SQUARE || mosaicShape > ANON_SHAPE_HEXAGON)
		mosaicShape = ANON_SHAPE_SQUARE;

	float* buf = (float*)malloc((size_t)w * h * 4 * sizeof(float));
	float* scratch = (float*)malloc((size_t)w * h * 4 * sizeof(float));
	if (buf == NULL || scratch == NULL)
	{
		free(buf);
		free(scratch);
		*gResult = memFullErr;
		return;
	}

	gFilterRecord->inputRate = (int32)1 << 16;
	gFilterRecord->maskRate = (int32)1 << 16;
	gFilterRecord->inLoPlane = 0;
	gFilterRecord->inHiPlane = (int16)(procPlanes - 1);
	gFilterRecord->outLoPlane = 0;
	gFilterRecord->outHiPlane = (int16)(procPlanes - 1);

	const VRect zeroRect = { 0, 0, 0, 0 };
	SetMaskRect(zeroRect);

	const int32 kBand = 256;
	const int32 bandsTotal = 2 * ((h + kBand - 1) / kBand);
	int32 bandsDone = 0;

	/* Gather the filtered region into the packed float buffer. */
	SetOutRect(zeroRect);
	for (int32 top = filterRect.top; top < filterRect.bottom; top += kBand)
	{
		VRect band = filterRect;
		band.top = top;
		band.bottom = std::min(top + kBand, filterRect.bottom);
		SetInRect(band);

		*gResult = gFilterRecord->advanceState();
		if (*gResult != noErr)
			goto cleanup;

		for (int32 y = band.top; y < band.bottom; ++y)
		{
			const uint8* row = (const uint8*)gFilterRecord->inData +
				(size_t)(y - band.top) * gFilterRecord->inRowBytes;
			float* out = buf + ((size_t)(y - filterRect.top) * w) * 4;
			for (int32 x = 0; x < w; ++x, out += 4)
			{
				const uint8* pixel = row + (size_t)x * gFilterRecord->inColumnBytes;
				out[0] = ReadChannel(pixel, depth, 0);
				out[1] = procPlanes > 1 ? ReadChannel(pixel, depth, 1) : 0.0f;
				out[2] = procPlanes > 2 ? ReadChannel(pixel, depth, 2) : 0.0f;
				out[3] = procPlanes > 3 ? ReadChannel(pixel, depth, 3) : 1.0f;
			}
		}

		gFilterRecord->progressProc(++bandsDone, bandsTotal);
		if (gFilterRecord->abortProc())
		{
			*gResult = userCanceledErr;
			goto cleanup;
		}
	}

	if (gParams->blackout)
	{
		/* Solid black, preserving any transparency plane. */
		const int colorPlanes =
			std::min(IsGrayMode(gFilterRecord->imageMode) ? 1 : 3, procPlanes);
		for (size_t i = 0; i < (size_t)w * h; ++i)
			for (int c = 0; c < colorPlanes; ++c)
				buf[i * 4 + c] = 0.0f;
	}
	else
	{
		AnonAlgo::RunLayeredPasses(buf, scratch, (int)w, (int)h,
			amount, scale, blurRadius, mosaicSize, mosaicShape, 0u);
	}

	/* Write the result back band by band. */
	SetInRect(zeroRect);
	for (int32 top = filterRect.top; top < filterRect.bottom; top += kBand)
	{
		VRect band = filterRect;
		band.top = top;
		band.bottom = std::min(top + kBand, filterRect.bottom);
		SetOutRect(band);

		*gResult = gFilterRecord->advanceState();
		if (*gResult != noErr)
			goto cleanup;

		for (int32 y = band.top; y < band.bottom; ++y)
		{
			uint8* row = (uint8*)gFilterRecord->outData +
				(size_t)(y - band.top) * gFilterRecord->outRowBytes;
			const float* in = buf + ((size_t)(y - filterRect.top) * w) * 4;
			for (int32 x = 0; x < w; ++x, in += 4)
			{
				uint8* pixel = row + (size_t)x * gFilterRecord->outColumnBytes;
				for (int c = 0; c < procPlanes; ++c)
					WriteChannel(pixel, depth, c, in[c]);
			}
		}

		gFilterRecord->progressProc(++bandsDone, bandsTotal);
		if (gFilterRecord->abortProc())
		{
			*gResult = userCanceledErr;
			goto cleanup;
		}
	}

cleanup:
	free(buf);
	free(scratch);
	SetInRect(zeroRect);
	SetOutRect(zeroRect);
	SetMaskRect(zeroRect);
}

/* ---- selectors ---- */

static void DoParameters(void)
{
	EnsureParametersHandle();
	EnsureData();
	if (*gResult == noErr && gData != NULL)
		gData->queryForParameters = true;
}

static void DoPrepare(void)
{
	EnsureParametersHandle();
	EnsureData();
	/* Buffers are plain malloc, outside Photoshop's budget. */
	gFilterRecord->bufferSpace = 0;
}

static void DoStart(void)
{
	EnsureParametersHandle();
	EnsureData();
	if (*gResult != noErr)
		return;
	LockParameters();
	if (*gResult != noErr)
		return;

	PSParameters saved = *gParams;

	bool run = true;
	if (gData->queryForParameters)
	{
		std::vector<float> proxyPixels;
		PSPreviewContext preview = {};
		const bool hasProxy = FetchProxy(proxyPixels, &preview);
		run = DoParamDialog(gParams, hasProxy ? &preview : NULL);
		gData->queryForParameters = false;
	}

	if (run)
	{
		DoFilterImpl();
	}
	else
	{
		*gParams = saved;
		*gResult = userCanceledErr;
	}
	UnlockParameters();
}

static void DoContinue(void)
{
	const VRect zeroRect = { 0, 0, 0, 0 };
	SetInRect(zeroRect);
	SetOutRect(zeroRect);
	SetMaskRect(zeroRect);
}

DLLExport MACPASCAL void PluginMain(const int16 selector,
	FilterRecordPtr filterRecord,
	intptr_t* data,
	int16* result)
{
	try
	{
		gFilterRecord = filterRecord;
		gResult = result;
		gData = (SessionData*)*data;

		if (selector != filterSelectorAbout &&
			gFilterRecord->bigDocumentData != NULL)
			gFilterRecord->bigDocumentData->PluginUsing32BitCoordinates = true;

		switch (selector)
		{
			case filterSelectorAbout:
				DoAboutDialog();
				break;
			case filterSelectorParameters:
				DoParameters();
				break;
			case filterSelectorPrepare:
				DoPrepare();
				break;
			case filterSelectorStart:
				DoStart();
				break;
			case filterSelectorContinue:
				DoContinue();
				break;
			case filterSelectorFinish:
				break;
			default:
				break;
		}

		*data = (intptr_t)gData;
	}
	catch (...)
	{
		if (result != NULL)
			*result = -1;
	}
}
