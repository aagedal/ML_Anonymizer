#include "AnonymizerAlgo.h"
#ifdef ANON_TEST_METAL
#include "AnonymizerPS.h"
#endif
#include <cmath>
#include <cstdio>
#include <utility>
#include <cstdlib>

static void check(bool ok, const char* message)
{
	if (!ok) { std::fprintf(stderr, "%s\n", message); std::exit(1); }
}

int main()
{
	check(AnonAlgo::BlurRadiusForOrderChange(15.0, true) == 35.0,
		"Enabling blur after mosaic should promote the default to 35");
	check(AnonAlgo::BlurRadiusForOrderChange(35.0, false) == 15.0,
		"Disabling blur after mosaic should restore the default to 15");
	for (double radius : {0.0, 10.0, 15.0, 20.0, 35.0, 100.0})
	{
		if (radius != BLUR_AFTER_MOSAIC_RADIUS_DFLT)
			check(AnonAlgo::BlurRadiusForOrderChange(radius, false) == radius,
				"Disabling blur after mosaic should preserve a customized radius");
		if (radius != BLUR_RADIUS_DFLT)
			check(AnonAlgo::BlurRadiusForOrderChange(radius, true) == radius,
				"Enabling blur after mosaic should preserve a customized radius");
	}
	int cases = 0;
	for (auto size : {std::pair<int, int>{1, 1}, {7, 3}, {31, 23}})
	for (int shape = 0; shape < 3; ++shape)
	for (float radius : {0.0f, 0.5f, 3.5f, 15.0f})
	for (float block : {1.0f, 5.0f, 40.0f})
	for (float amount : {0.0f, 4.0f})
	{
		const int w = size.first, h = size.second;
		std::vector<float> input((size_t)w * h * 4);
		for (size_t i = 0; i < input.size(); ++i)
			input[i] = (float)((i * 37 + i / 7) % 101) / 100.0f;
		std::vector<float> a(input.size()), b(input.size()), scratch(input.size());
		for (bool after : {false, true})
		{
			// Explicit reference stages verify ordering and final buffer ownership.
			AnonAlgo::DistortPass(input.data(), a.data(), w, h, amount, 5.0f, 42u);
			if (after)
			{
				AnonAlgo::MosaicPass(a.data(), b.data(), w, h, block, shape);
				AnonAlgo::BlurPass(b.data(), a.data(), w, h, radius, 0);
				AnonAlgo::BlurPass(a.data(), b.data(), w, h, radius, 1);
			}
			else
			{
				AnonAlgo::BlurPass(a.data(), b.data(), w, h, radius, 0);
				AnonAlgo::BlurPass(b.data(), a.data(), w, h, radius, 1);
				AnonAlgo::MosaicPass(a.data(), b.data(), w, h, block, shape);
			}
			a = input;
			AnonAlgo::RunLayeredPasses(a.data(), scratch.data(), w, h,
				amount, 5.0f, radius, block, shape, 42u, after);
			check(a == b, "CPU stage order differs from reference");
			if (!after)
			{
				a = input;
				AnonAlgo::RunLayeredPasses(a.data(), scratch.data(), w, h,
					amount, 5.0f, radius, block, shape, 42u);
				check(a == b, "Default output changed");
			}
#ifdef ANON_TEST_METAL
			a = input;
			check(RunMetalPasses(a.data(), w, h, amount, 5.0f, radius, block,
				shape, 42u, after), "Metal pipeline failed");
			for (size_t i = 0; i < a.size(); ++i)
				check(std::isfinite(a[i]) && std::abs(a[i] - b[i]) < 2e-5f,
					"CPU/Metal output differs");
#endif
			++cases;
		}
		if (radius == 0.0f)
		{
			a = input;
			b = input;
			AnonAlgo::RunLayeredPasses(a.data(), scratch.data(), w, h,
				amount, 5.0f, radius, block, shape, 42u, false);
			AnonAlgo::RunLayeredPasses(b.data(), scratch.data(), w, h,
				amount, 5.0f, radius, block, shape, 42u, true);
			check(a == b, "Zero blur should make both orders identical");
		}
	}
	std::printf("Passed %d processing-order cases\n", cases);
}
