/*
** Multi-Layer Anonymizer - CPU (software) render path and AE-style plugin
** entry point.
**
** In Premiere Pro this path is used when GPU acceleration is unavailable or
** the renderer is set to Mercury Software Only; with GPU acceleration the
** Metal path in Anonymizer_GPU.mm renders instead. The algorithm is kept
** identical between the two paths (same hashes, same sampling) so switching
** renderers does not change the picture.
*/

#include "Anonymizer.h"

namespace
{

using namespace AnonAlgo;

/*
** ---- AE-style command handlers ----
*/

PF_Err GlobalSetup(
	PF_InData* in_data,
	PF_OutData* out_data,
	PF_ParamDef* params[],
	PF_LayerDef* output)
{
	out_data->my_version = PF_VERSION(MAJOR_VERSION, MINOR_VERSION, BUG_VERSION, STAGE_VERSION, BUILD_VERSION);
	out_data->out_flags = ANONYMIZER_OUT_FLAGS;
	out_data->out_flags2 = ANONYMIZER_OUT_FLAGS2;

	if (in_data->appl_id == 'PrMr')
	{
		// Ask Premiere for full float frames so the software path matches the
		// GPU path in precision. The passes are channel-order agnostic.
		AEFX_SuiteScoper<PF_PixelFormatSuite1> pixelFormatSuite(
			in_data, kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1, out_data);
		(*pixelFormatSuite->ClearSupportedPixelFormats)(in_data->effect_ref);
		(*pixelFormatSuite->AddSupportedPixelFormat)(in_data->effect_ref, PrPixelFormat_BGRA_4444_32f);
	}

	return PF_Err_NONE;
}

PF_Err ParamsSetup(
	PF_InData* in_data,
	PF_OutData* out_data,
	PF_ParamDef* params[],
	PF_LayerDef* output)
{
	PF_ParamDef def;

	AEFX_CLR_STRUCT(def);
	PF_ADD_FLOAT_SLIDERX("Distortion Amount",
		DISTORT_AMOUNT_MIN, DISTORT_AMOUNT_MAX,
		DISTORT_AMOUNT_MIN, DISTORT_AMOUNT_MAX,
		DISTORT_AMOUNT_DFLT, PF_Precision_TENTHS,
		PF_ValueDisplayFlag_NONE, 0, ANON_DISTORT_AMOUNT);

	AEFX_CLR_STRUCT(def);
	PF_ADD_FLOAT_SLIDERX("Distortion Scale",
		DISTORT_SCALE_MIN, DISTORT_SCALE_MAX,
		DISTORT_SCALE_MIN, DISTORT_SCALE_MAX,
		DISTORT_SCALE_DFLT, PF_Precision_TENTHS,
		PF_ValueDisplayFlag_NONE, 0, ANON_DISTORT_SCALE);

	AEFX_CLR_STRUCT(def);
	PF_ADD_FLOAT_SLIDERX("Blur Radius",
		BLUR_RADIUS_MIN, BLUR_RADIUS_MAX,
		BLUR_RADIUS_MIN, BLUR_RADIUS_MAX,
		BLUR_RADIUS_DFLT, PF_Precision_TENTHS,
		PF_ValueDisplayFlag_NONE, 0, ANON_BLUR_RADIUS);

	AEFX_CLR_STRUCT(def);
	PF_ADD_FLOAT_SLIDERX("Mosaic Block Size",
		MOSAIC_SIZE_MIN, MOSAIC_SIZE_MAX,
		MOSAIC_SIZE_MIN, MOSAIC_SIZE_MAX,
		MOSAIC_SIZE_DFLT, PF_Precision_TENTHS,
		PF_ValueDisplayFlag_NONE, 0, ANON_MOSAIC_SIZE);

	AEFX_CLR_STRUCT(def);
	PF_ADD_FLOAT_SLIDERX("Random Seed",
		SEED_MIN, SEED_MAX,
		SEED_MIN, SEED_MAX,
		SEED_DFLT, PF_Precision_INTEGER,
		PF_ValueDisplayFlag_NONE, 0, ANON_SEED);

	AEFX_CLR_STRUCT(def);
	PF_ADD_CHECKBOXX("Temporal Jitter",
		TRUE, 0, ANON_TEMPORAL_JITTER);

	AEFX_CLR_STRUCT(def);
	PF_ADD_CHECKBOXX("Blackout",
		FALSE, 0, ANON_BLACKOUT);

	AEFX_CLR_STRUCT(def);
	PF_ADD_POPUP("Mosaic Shape",
		3, ANON_SHAPE_SQUARE + 1,
		"Square|Triangle|Hexagon",
		ANON_MOSAIC_SHAPE);

	AEFX_CLR_STRUCT(def);
	PF_ADD_CHECKBOXX("Blur After Mosaic",
		FALSE, 0, ANON_BLUR_AFTER_MOSAIC);

	out_data->num_params = ANON_NUM_PARAMS;
	return PF_Err_NONE;
}

PF_Err Render(
	PF_InData* in_data,
	PF_OutData* out_data,
	PF_ParamDef* params[],
	PF_LayerDef* output)
{
	PF_LayerDef* src = &params[ANON_INPUT]->u.ld;
	const int w = output->width;
	const int h = output->height;
	if (w <= 0 || h <= 0)
		return PF_Err_NONE;

	// Pixel-space parameters are relative to 1080p; scaling by the shorter
	// frame dimension keeps the anonymization strength constant across
	// resolutions and orientations (portrait vs landscape timelines).
	const float ds = AnonResolutionScale(w, h);

	float amount = (float)params[ANON_DISTORT_AMOUNT]->u.fs_d.value * ds;
	float scale = std::max((float)params[ANON_DISTORT_SCALE]->u.fs_d.value * ds, 2.0f);
	float blurRadius = (float)params[ANON_BLUR_RADIUS]->u.fs_d.value * ds;
	float mosaicSize = (float)params[ANON_MOSAIC_SIZE]->u.fs_d.value * ds;
	double seedParam = params[ANON_SEED]->u.fs_d.value;
	bool jitter = params[ANON_TEMPORAL_JITTER]->u.bd.value != 0;
	// Popup values are 1-based.
	int mosaicShape = params[ANON_MOSAIC_SHAPE]->u.pd.value - 1;
	if (mosaicShape < ANON_SHAPE_SQUARE || mosaicShape > ANON_SHAPE_HEXAGON)
		mosaicShape = ANON_SHAPE_SQUARE;

	int32_t frame = 0;
	if (in_data->time_step != 0)
		frame = (int32_t)(in_data->current_time / in_data->time_step);
	uint32_t seed = AnonComputeSeed(seedParam, jitter, frame);

	const bool isFloatWorld = (in_data->appl_id == 'PrMr');

	// Blackout: replace RGB with solid black, keep the source alpha so effect
	// masks and transparency behave normally. Alpha is channel 3 in Premiere's
	// BGRA floats, channel 0 in AE's 8-bit ARGB.
	if (params[ANON_BLACKOUT]->u.bd.value)
	{
		const char* srcRow = (const char*)src->data;
		char* dstRow = (char*)output->data;
		for (int y = 0; y < h; ++y, srcRow += src->rowbytes, dstRow += output->rowbytes)
		{
			if (isFloatWorld)
			{
				const float* in = (const float*)srcRow;
				float* out = (float*)dstRow;
				for (int x = 0; x < w; ++x)
				{
					out[x * 4 + 0] = 0.0f;
					out[x * 4 + 1] = 0.0f;
					out[x * 4 + 2] = 0.0f;
					out[x * 4 + 3] = in[x * 4 + 3];
				}
			}
			else
			{
				const A_u_char* in = (const A_u_char*)srcRow;
				A_u_char* out = (A_u_char*)dstRow;
				for (int x = 0; x < w; ++x)
				{
					out[x * 4 + 0] = in[x * 4 + 0];
					out[x * 4 + 1] = 0;
					out[x * 4 + 2] = 0;
					out[x * 4 + 3] = 0;
				}
			}
		}
		return PF_Err_NONE;
	}

	std::vector<float> bufA((size_t)w * h * 4);
	std::vector<float> bufB((size_t)w * h * 4);

	// Load the source world into a packed float buffer.
	if (isFloatWorld)
	{
		const char* srcRow = (const char*)src->data;
		for (int y = 0; y < h; ++y, srcRow += src->rowbytes)
			memcpy(&bufA[(size_t)y * w * 4], srcRow, (size_t)w * 4 * sizeof(float));
	}
	else
	{
		const char* srcRow = (const char*)src->data;
		for (int y = 0; y < h; ++y, srcRow += src->rowbytes)
		{
			const A_u_char* p = (const A_u_char*)srcRow;
			float* out = &bufA[(size_t)y * w * 4];
			for (int x = 0; x < w * 4; ++x)
				out[x] = (float)p[x] * (1.0f / 255.0f);
		}
	}

	// Distortion followed by blur/mosaic in the selected order. Result in bufA.
	RunLayeredPasses(bufA.data(), bufB.data(), w, h, amount, scale, blurRadius, mosaicSize, mosaicShape, seed,
		params[ANON_BLUR_AFTER_MOSAIC]->u.bd.value != 0);

	// Store to the output world.
	if (isFloatWorld)
	{
		char* dstRow = (char*)output->data;
		for (int y = 0; y < h; ++y, dstRow += output->rowbytes)
			memcpy(dstRow, &bufA[(size_t)y * w * 4], (size_t)w * 4 * sizeof(float));
	}
	else
	{
		char* dstRow = (char*)output->data;
		for (int y = 0; y < h; ++y, dstRow += output->rowbytes)
		{
			A_u_char* p = (A_u_char*)dstRow;
			const float* in = &bufA[(size_t)y * w * 4];
			for (int x = 0; x < w * 4; ++x)
			{
				float v = in[x] * 255.0f + 0.5f;
				p[x] = (A_u_char)std::min(std::max(v, 0.0f), 255.0f);
			}
		}
	}

	return PF_Err_NONE;
}

} // namespace

/*
** Plugin entry point, referenced by CodeMacIntel64 / CodeMacARM64 in the PiPL.
*/
#ifdef AE_OS_WIN
#define DllExport __declspec(dllexport)
#else
#define DllExport __attribute__((visibility("default")))
#endif

extern "C" DllExport PF_Err EffectMain(
	PF_Cmd inCmd,
	PF_InData* in_data,
	PF_OutData* out_data,
	PF_ParamDef* params[],
	PF_LayerDef* inOutput,
	void* extra)
{
	PF_Err err = PF_Err_NONE;
	switch (inCmd)
	{
	case PF_Cmd_GLOBAL_SETUP:
		err = GlobalSetup(in_data, out_data, params, inOutput);
		break;
	case PF_Cmd_GLOBAL_SETDOWN:
		break;
	case PF_Cmd_PARAMS_SETUP:
		err = ParamsSetup(in_data, out_data, params, inOutput);
		break;
	case PF_Cmd_RENDER:
		err = Render(in_data, out_data, params, inOutput);
		break;
	default:
		break;
	}
	return err;
}
