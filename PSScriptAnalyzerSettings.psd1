@{
    ExcludeRules = @(
        # A status line exists to write to the host, so this rule is noise here.
        'PSAvoidUsingWriteHost',
        # The script and its tests call small local helpers positionally (C '90' $text); naming every argument would only add bulk.
        'PSAvoidUsingPositionalParameters'
    )
}
