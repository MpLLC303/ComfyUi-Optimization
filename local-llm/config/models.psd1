# Model catalog for the local AI stack. Edit this file to add, swap or drop models; the
# installer, Test-LocalAI.ps1 and the presets in Open WebUI are all driven from it.
#
#   Source      Ollama tag that gets pulled (the raw community model).
#   Alias       Thin Ollama model created FROM Source with the tuned num_ctx, sampling
#               parameters and system prompt baked in. Shares the weights; costs no disk.
#   Preset      Open WebUI workspace model id that users pick in the chat selector.
#   MaxContext  Upper bound for the context auto-tuner. The tuner also never exceeds the
#               model's trained context (Qwen3-14B: 40960) and stops at the largest value
#               that stays 100% on the GPU.
#   Parameters  Sampling defaults from the Qwen model cards (instruct: 0.7/0.8/20,
#               thinking: 0.6/0.95/20, coder adds repeat_penalty 1.05).
#   Think       $false = preset sends think:false (no reasoning trace, faster first token). Set when
#               the preset is created; a Think value changed later on the preset is kept by re-runs.
#               Open WebUI 0.11.4 re-applies the preset's value over the per-chat Chat Controls
#               switch, so the preset (Workspace > Models) is the only place to change it.
#   MinTokensPerSec  Below this, the install report flags the model as probably spilling
#                    out of VRAM. Set at roughly half of what a healthy RTX 3090 delivers.
#   Trial       $true = newer model offered as an extra preset only when asked for with
#               Install-LocalAI.ps1 -TrialModels <key>. A trial whose tag is missing, that this
#               Ollama cannot load, or that is not 100% on the GPU is skipped with a warning; the
#               four measured presets are never replaced. Their speeds are estimates until tuned.
@{
    DefaultPreset     = 'local-main'
    ContextCandidates = @(65536, 57344, 49152, 40960, 32768, 24576, 16384, 12288, 8192)

    Models            = @(
        @{
            Key             = 'fast'
            Order           = 2
            Display         = 'Local Fast'
            Preset          = 'local-fast'
            Alias           = 'localai-fast'
            Source          = 'huihui_ai/qwen3-abliterated:14b-v2'
            Optional        = $false
            DownloadGB      = 9.3
            MaxContext      = 40960
            Vision          = $false
            Think           = $false
            MinTokensPerSec = 40
            Parameters      = @{ temperature = 0.6; top_p = 0.95; top_k = 20; min_p = 0.0 }
            Description     = 'Qwen3 14B abliterated (dense, hybrid reasoning). Thinking is off; for step-by-step answers set Think on in Workspace > Models > Local Fast > Advanced Params (the per-chat Chat Controls switch cannot override it).'
        }
        @{
            Key             = 'main'
            Order           = 1
            Display         = 'Local Main'
            Preset          = 'local-main'
            Alias           = 'localai-main'
            Source          = 'huihui_ai/qwen3-abliterated:30b-a3b-instruct-2507-q4_K_M'
            Optional        = $false
            DownloadGB      = 18.6
            MaxContext      = 65536
            Vision          = $false
            Think           = $null
            MinTokensPerSec = 95
            Parameters      = @{ temperature = 0.7; top_p = 0.8; top_k = 20; min_p = 0.0 }
            Description     = 'Qwen3 30B-A3B Instruct 2507 abliterated (mixture of experts, ~3B active per token). Default daily driver.'
        }
        @{
            Key             = 'vision'
            Order           = 3
            Display         = 'Local Vision'
            Preset          = 'local-vision'
            Alias           = 'localai-vision'
            Source          = 'huihui_ai/qwen3-vl-abliterated:30b-a3b-instruct-q4_K_M'
            Optional        = $true
            DownloadGB      = 20.0
            MaxContext      = 32768
            Vision          = $true
            Think           = $null
            MinTokensPerSec = 90
            Parameters      = @{ temperature = 0.7; top_p = 0.8; top_k = 20; min_p = 0.0 }
            Description     = 'Qwen3-VL 30B-A3B Instruct abliterated. Use this preset when you attach images.'
        }
        @{
            Key             = 'code'
            Order           = 4
            Display         = 'Local Code'
            Preset          = 'local-code'
            Alias           = 'localai-code'
            Source          = 'huihui_ai/qwen3-coder-abliterated:30b-a3b-instruct-q4_K_M'
            Optional        = $true
            DownloadGB      = 18.6
            MaxContext      = 65536
            Vision          = $false
            Think           = $null
            MinTokensPerSec = 90
            Parameters      = @{ temperature = 0.7; top_p = 0.8; top_k = 20; min_p = 0.0; repeat_penalty = 1.05 }
            Description     = 'Qwen3-Coder 30B-A3B Instruct abliterated. Coding and agentic-coding specialist.'
        }
        # ---- trials (opt-in; see Trial above) ---------------------------------------------------
        @{
            Key             = 'trial-fast'
            Order           = 5
            Display         = 'Trial: Qwen3.5 9B (fast)'
            Preset          = 'trial-qwen35-9b'
            Alias           = 'localai-trial-qwen35-9b'
            Source          = 'huihui_ai/qwen3.5-abliterated:9b'
            Optional        = $true
            Trial           = $true
            DownloadGB      = 6.6
            MaxContext      = 65536
            Vision          = $false
            Think           = $false
            MinTokensPerSec = 60
            Parameters      = @{ temperature = 0.6; top_p = 0.95; top_k = 20; min_p = 0.0 }
            Description     = 'Trial: Qwen3.5 9B abliterated (dense, 2026). Candidate replacement for Local Fast: smaller, newer, much longer context.'
        }
        @{
            Key             = 'trial-gemma4'
            Order           = 6
            Display         = 'Trial: Gemma 4 26B'
            Preset          = 'trial-gemma4-26b'
            Alias           = 'localai-trial-gemma4-26b'
            Source          = 'huihui_ai/gemma-4-abliterated:26b'
            Optional        = $true
            Trial           = $true
            DownloadGB      = 18
            MaxContext      = 65536
            Vision          = $true
            Think           = $null
            MinTokensPerSec = 65
            Parameters      = @{ temperature = 1.0; top_p = 0.95; top_k = 64; min_p = 0.0 }
            Description     = 'Trial: Gemma 4 26B abliterated (mixture of experts, ~3.8B active, images). Candidate for Main/Vision; check refusals before relying on it.'
        }
        @{
            Key             = 'trial-code27b'
            Order           = 7
            Display         = 'Trial: Qwen3.6 27B (slow, careful)'
            Preset          = 'trial-qwen36-27b'
            Alias           = 'localai-trial-qwen36-27b'
            Source          = 'huihui_ai/qwen3.6-abliterated:27b'
            Optional        = $true
            Trial           = $true
            DownloadGB      = 17
            MaxContext      = 65536
            Vision          = $true
            Think           = $null
            MinTokensPerSec = 18
            Parameters      = @{ temperature = 0.6; top_p = 0.95; top_k = 20; min_p = 0.0 }
            Description     = 'Trial: Qwen3.6 27B abliterated (dense, 2026). Quality-first coding and reasoning at roughly a fifth of Local Code speed.'
        }
    )
}
