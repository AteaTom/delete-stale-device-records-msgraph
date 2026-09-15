@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost', # Used intentionally for the human-facing summary/confirmation UI.
        'PSUseSingularNouns', # Discovery functions intentionally return collections (e.g. Get-EntraDeviceRecords).
        'PSUseShouldProcessForStateChangingFunctions', # Connect/Test/Wait helpers are non-destructive; only Remove-* functions are destructive and those implement ShouldProcess.
        'PSReviewUnusedParameter', # False positives against Pester 5's BeforeAll/It/Describe DSL parameter blocks.
        'PSUseDeclaredVarsMoreThanAssignments' # False positives against Pester 5's scoped test variables.
    )
    Rules        = @{
        PSAvoidUsingCmdletAliases     = @{ Enable = $true }
        PSProvideCommentHelp          = @{ Enable = $false }
    }
}
