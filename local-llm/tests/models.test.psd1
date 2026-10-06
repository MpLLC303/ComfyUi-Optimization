# Test catalog for tests/Invoke-IntegrationTest.ps1: one small Qwen3 (same architecture family
# and chat template as the real models) standing in for the 14B/30B, so the run fits on a CPU box.
@{
    DefaultPreset     = 'local-main'
    # The installer mock run: new chats start on the official stand-in once it is set up.
    PreferredDefaultPreset = 'official-standin'
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
        @{
            Key             = 'official-ok'
            Order           = 3
            Display         = 'Official: stand-in'
            Preset          = 'official-standin'
            Alias           = 'localai-official-standin'
            Source          = 'testorg/qwen3-abliterated:1.7b'
            Optional        = $true
            Official        = $true
            DownloadGB      = 1.1
            MaxContext      = 8192
            Vision          = $false
            Think           = $false
            MinTokensPerSec = 1
            Parameters      = @{ temperature = 0.6; top_p = 0.95; top_k = 20; min_p = 0.0 }
            Description     = 'Official-release preset that works (installed by default).'
        }
        @{
            Key             = 'official-missing'
            Order           = 4
            Display         = 'Official: missing tag'
            Preset          = 'official-missing'
            Alias           = 'localai-official-missing'
            Source          = 'testorg/official-does-not-exist:1b'
            Optional        = $true
            Official        = $true
            DownloadGB      = 0   # 0 so the disk planner admits it and the pull itself must fail
            MaxContext      = 8192
            Vision          = $false
            Think           = $false
            MinTokensPerSec = 1
            Parameters      = @{ temperature = 0.6 }
            Description     = 'Official release whose tag cannot be pulled; skipped, recorded, not retried every run.'
        }
        @{
            Key             = 'trial-ok'
            Order           = 5
            Display         = 'Trial: stand-in'
            Preset          = 'trial-standin'
            Alias           = 'localai-trial-standin'
            Source          = 'testorg/qwen3-abliterated:1.7b'
            Optional        = $true
            Trial           = $true
            DownloadGB      = 1.1
            MaxContext      = 8192
            Vision          = $false
            Think           = $false
            MinTokensPerSec = 1
            Parameters      = @{ temperature = 0.6; top_p = 0.95; top_k = 20; min_p = 0.0 }
            Description     = 'Trial preset that works.'
        }
        @{
            Key             = 'trial-missing'
            Order           = 6
            Display         = 'Trial: missing tag'
            Preset          = 'trial-missing'
            Alias           = 'localai-trial-missing'
            Source          = 'testorg/does-not-exist:1b'
            Optional        = $true
            Trial           = $true
            DownloadGB      = 0   # 0 so the disk planner admits it and the pull itself must fail
            MaxContext      = 8192
            Vision          = $false
            Think           = $false
            MinTokensPerSec = 1
            Parameters      = @{ temperature = 0.6 }
            Description     = 'Trial whose tag cannot be pulled; must be skipped, not fatal.'
        }
    )
}
