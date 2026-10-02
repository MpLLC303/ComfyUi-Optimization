# Test catalog for tests/Invoke-IntegrationTest.ps1: one small Qwen3 (same architecture family
# and chat template as the real models) standing in for the 14B/30B, so the run fits on a CPU box.
@{
    DefaultPreset     = 'local-main'
    ContextCandidates = @(65536, 32768, 16384, 8192)
    Models            = @(
        @{
            Key             = 'main'
            Order           = 1
            Display         = 'Local Main'
            Preset          = 'local-main'
            Alias           = 'localai-main'
            Source          = 'testorg/qwen3-abliterated:1.7b'
            Optional        = $false
            DownloadGB      = 1.1
            MaxContext      = 16384
            Vision          = $false
            Think           = $null
            MinTokensPerSec = 1
            Parameters      = @{ temperature = 0.7; top_p = 0.8; top_k = 20; min_p = 0.0 }
            Description     = 'Integration-test stand-in for the 30B.'
        }
        @{
            Key             = 'fast'
            Order           = 2
            Display         = 'Local Fast'
            Preset          = 'local-fast'
            Alias           = 'localai-fast'
            Source          = 'testorg/qwen3-abliterated:1.7b'
            Optional        = $false
            DownloadGB      = 1.1
            MaxContext      = 8192
            Vision          = $false
            Think           = $false
            MinTokensPerSec = 1
            Parameters      = @{ temperature = 0.6; top_p = 0.95; top_k = 20; min_p = 0.0 }
            Description     = 'Integration-test stand-in for the 14B.'
        }
    )
}
