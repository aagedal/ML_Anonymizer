/*
** Multi-Layer Anonymizer - PiPL resource.
**
** AE_Effect_Global_OutFlags must match ANONYMIZER_OUT_FLAGS in Anonymizer.h
** (PF_OutFlag_NON_PARAM_VARY = 0x00000004).
** AE_Effect_Version encodes PF_VERSION(1,4,0,PF_Stage_DEVELOP,0) = 655360.
** AE_Effect_Match_Name must match ANONYMIZER_MATCH_NAME in Anonymizer.h.
*/

#include "AEConfig.h"
#include "AE_EffectVers.h"

#ifndef AE_OS_WIN
	#include "AE_General.r"
#endif

/* Branding macros are injected by the build (see ANON_EDITION in
** CMakeLists.txt); the fallbacks are the open-source edition. */
#ifndef ANON_PIPL_NAME
	#define ANON_PIPL_NAME "Multi-Layer Anonymizer"
#endif
#ifndef ANON_PIPL_CATEGORY
	#define ANON_PIPL_CATEGORY "Aagedal"
#endif
#ifndef ANON_PIPL_MATCH_NAME
	#define ANON_PIPL_MATCH_NAME "AGDL Multi-Layer Anonymizer"
#endif

resource 'PiPL' (16000) {
	{
		Kind {
			AEEffect
		},
		Name {
			ANON_PIPL_NAME
		},
		Category {
			ANON_PIPL_CATEGORY
		},

#ifdef AE_OS_WIN
		CodeWin64X86 {"EffectMain"},
#else
		CodeMacIntel64 {"EffectMain"},
		CodeMacARM64 {"EffectMain"},
#endif

		AE_PiPL_Version {
			2,
			0
		},
		AE_Effect_Spec_Version {
			PF_PLUG_IN_VERSION,
			PF_PLUG_IN_SUBVERS
		},
		AE_Effect_Version {
			655360 /* 1.4 */
		},
		AE_Effect_Info_Flags {
			0
		},
		AE_Effect_Global_OutFlags {
			0x00000004
		},
		AE_Effect_Global_OutFlags_2 {
			0x00000000
		},
		AE_Effect_Match_Name {
			ANON_PIPL_MATCH_NAME
		},
		AE_Reserved_Info {
			8
		}
	}
};
