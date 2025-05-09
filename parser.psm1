using module .\cmdb_handle.psm1

###################
# SECTION PARSING #
###################

# Represents a successfully parsed object.
#
# Fields:
#   [Object]$val - The extracted and/or mapped value.
#   [String]$rem - Substring without the parsed part.
class ParseResult {
    [Object]$val
    [String]$rem
    ParseResult([Object]$val, [String]$rem) {
        $this.val = $val; $this.rem = $rem
    }
}

# Parses a regex pattern.
# Extracts the named capture group 'val'.
#
# Arguments:
#   [String]$expr - The input expression.
#   [Regex]$regx - The regex pattern to match.
#
# Returns:
#   A `ParseResult` with the extracted value of the `val` capture group.
#   `$null` on failure.
function ParsePattern {
    param ([String]$expr, [Regex]$regx)
    if ($expr -match $regx) {
        return [ParseResult]::New($Matches["val"], $expr.Substring($Matches[0].Length))
    } else { return $null }
}

# Parses a string value.
# Supports plain, single-quoted, and double-quoted strings.
#
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `ParseResult` with the extracted string value, unescaped.
#   `$null` on failure.
function ParseString {
    param ([String]$expr)
    [String]$plain = "(?<val>(\\.|[^\s`"'!=~<>&|()])+)"
    [String]$single = "'(?<val>(\\.|[^'])*)'"
    [String]$double = "`"(?<val>(\\.|[^`"])*)`""
    [ParseResult]$str = ParsePattern $expr "^\s*($plain|$single|$double)"
    if ($null -eq $str) { return $null }
    $str.val = $str.val -replace "\\(.)", '$1'
    return $str
}

# Parses a comparison operator.
# Valid operators are:
# ~  =~  (IsMatch)
# !~     (IsNotMatch)
# =  ==  (IsEqual)
# != <>  (IsNotEqual)
# <      (LessThan)
# <=     (LessThanOrEqual)
# >      (GreaterThan)
# >=     (GreaterThanOrEqual)
#
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `ParseResult` with the extracted operator.
#   `$null` if no operator was found.
function ParseOperator {
    param ([String]$expr)
    return ParsePattern $expr "^\s*(?<val>(=?~|!~|==?|!=|<>|<=?|>=?))"
}

# Parses an AND combinator (&&, & or "AND").
#
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `ParseResult` with the extracted AND combinator.
#   `$null` if no AND combinator was found.
function ParseAnd {
    param ([String]$expr)
    return ParsePattern $expr "(?i)^\s*(?<val>(&{1,2}|and))"
}

# Parses an OR combinator (||, | or "OR").
#
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `ParseResult` with the extracted OR combinator.
#   `$null` if no OR combinator was found.
function ParseOr {
    param ([String]$expr)
    return ParsePattern $expr "(?i)^\s*(?<val>(\|{1,2}|or))"
}

# Maps a parsed operator string to a `CmdbOperator` enum value.
# Valid operators are:
# ~  =~  (IsMatch)
# !~     (IsNotMatch)
# =  ==  (IsEqual)
# != <>  (IsNotEqual)
# <      (LessThan)
# <=     (LessThanOrEqual)
# >      (GreaterThan)
# >=     (GreaterThanOrEqual)
#
# Arguments:
#   [String]$op_str - The operator string to map.
#
# Returns:
#   The corresponding `CmdbOperator` enum value.
#
# Throws on failure.
function MapOperator {
    param ([String]$op_str)
    switch ($op_str) {
        ("~")   { return [CmdbOperator]::IsMatch }
        ("=~")  { return [CmdbOperator]::IsMatch }
        ("!~")  { return [CmdbOperator]::IsNotMatch }
        ("=")   { return [CmdbOperator]::IsEqual }
        ("==")  { return [CmdbOperator]::IsEqual }
        ("!=")  { return [CmdbOperator]::IsNotEqual }
        ("<>")  { return [CmdbOperator]::IsNotEqual }
        ("<")   { return [CmdbOperator]::LessThan }
        ("<=")  { return [CmdbOperator]::LessThanOrEqual }
        (">")   { return [CmdbOperator]::GreaterThan }
        (">=")  { return [CmdbOperator]::GreaterThanOrEqual }
        default { throw "'$op_str' is not a valid operator" }
    }
}

# Represents the type of a logical Term.
# Can be one of the following:
#   Comparison       <field> <operator> <value>
#   Combination      <term> <combinator> <term>
#   FlatCombination  <term> <combinator> ...
#   Inversion        Not <term> or !<term>
#   Boolean          True or False
#   Symbol           <any identifier>
enum TermType {
    Comparison
    Combination
    FlatCombination
    Inversion
    Boolean
    Symbol
}

# Parses a single comparison (e.g., `age >= 30`).
# The left and right side are parsed as any valid string value.
#
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   - This Term is always a Comparison.
#   `$null` on failure.
#
# Throws on an empty `field` string.
# Throws on an operator without following value.
function ParseComparison {
    param ([String]$expr)
    [ParseResult]$field = ParseString $expr; if ($field) { $expr = $field.rem } else { return $null }
    [ParseResult]$oper = ParseOperator $expr; if ($oper) { $expr = $oper.rem } else { return $null }
    [ParseResult]$value = ParseString $expr
    if (-not $value) { throw "Expected Value after '$($oper.val)'" }
    if (-not $field.val) { throw "Found Comparison with an empty field" }
    return [ParseResult]::New([PSCustomObject]@{
        term_type = [TermType]::Comparison
        value = [PSCustomObject]@{
            field = $field.val
            value = $value.val
            operator = MapOperator $oper.val
        }
    }, $value.rem)
}

# Converts a boolean value to a Term.
#
# Arguments:
#   [Bool]$value - The value of the boolean.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   - `value` holds the boolean.
function BoolTerm {
    param ([Bool]$value)
    return [PSCustomObject]@{
        term_type = [TermType]::Boolean
        value = $value
    }
}

# Parses a boolean expression (True or False).
# 
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   - This Term is always a Boolean.
#   `$null` on failure.
function ParseBool {
    param ([String]$expr)
    [ParseResult]$bool = ParsePattern $expr "(?i)^\s*(?<val>true|false)"
    if (-not $bool) { return $null }
    [Bool]$val = $bool.val.ToLower() -eq "true"
    return [ParseResult]::New((BoolTerm $val), $bool.rem)
}

# Parses a Symbolic Term.
# The Symbol has to starts with a letter (a-z),
# and can contain letters, numbers, '-' and '_'.
# 
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   - This Term is always a Symbol.
#   `$null` on failure.
function ParseSymbol {
    param ([String]$expr)
    [ParseResult]$sym = ParsePattern $expr "(?i)^\s*(?<val>[a-z][0-9a-z_-]*)"; if (-not $sym) { return $null }
    return [ParseResult]::New([PSCustomObject]@{ term_type = [TermType]::Symbol; value = $sym.val }, $sym.rem)
}

# Parses a grouped expression in parentheses.
# 
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   $null on failure.
#
# Throws on inversion without following parentheses.
# Throws on any unmatched opening parentheses.
function ParseGroupedTerm {
    param ([String]$expr)
    [ParseResult]$lparen = ParsePattern $expr "^\s*\("
    if ($lparen) { $expr = $lparen.rem } else { return $null }
    [ParseResult]$inner = ParseTermChain $expr
    if ($inner) { $expr = $inner.rem } else { throw "Expected Expression inside Parentheses" }
    [ParseResult]$rparen = ParsePattern $expr "^\s*\)"
    if (-not $rparen) { throw "Found unmatched '('" }
    return [ParseResult]::New($inner.val, $rparen.rem)
}

# Parses an inverse term.
# The inverted value can be another inversion, a symbol,
# or a grouped subexpression in parentheses.
# 
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   $null on failure.
#
# Throws on inversion with following comparison.
function ParseInverseTerm {
    param ([String]$expr)
    [ParseResult]$inv = ParsePattern $expr "(?i)^\s*(?<val>!|not)"
    if ($inv) { $expr = $inv.rem } else { return $null }
    [ParseResult]$comp = ParseComparison $expr
    if ($comp) { throw "Expected Parentheses or Symbol after '$($inv.val)'" }
    [ParseResult]$inv = ParseInverseTerm $expr
    if ($inv) { return [ParseResult]::New([PSCustomObject]@{
        term_type = [TermType]::Inversion; value = $inv.val
    }, $inv.rem) }
    [ParseResult]$group = ParseGroupedTerm $expr
    if ($group) { return [ParseResult]::New([PSCustomObject]@{
        term_type = [TermType]::Inversion; value = $group.val
    }, $group.rem) }
    [ParseResult]$bool = ParseBool $expr
    if ($bool) { return [ParseResult]::New([PSCustomObject]@{
        term_type = [TermType]::Inversion; value = $bool.val
    }, $bool.rem) }
    [ParseResult]$symbol = ParseSymbol $expr
    if ($symbol) { return [ParseResult]::New([PSCustomObject]@{
        term_type = [TermType]::Inversion; value = $symbol.val
    }, $symbol.rem) }
    return $null
}

# Parses a term, which can be a comparison, an inversion,
# a grouped subexpression in parentheses, a boolean value,
# or a symbol.
#
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   $null on failure.
#
# Throws on inversion with following comparison.
# Throws on any unmatched opening parentheses.
function ParseTerm {
    param ([String]$expr)
    [ParseResult]$comp = ParseComparison $expr; if ($comp) { return $comp }
    [ParseResult]$group = ParseGroupedTerm $expr; if ($group) { return $group }
    [ParseResult]$inv = ParseInverseTerm $expr; if ($inv) { return $inv }
    [ParseResult]$bool = ParseBool $expr; if ($bool) { return $bool }
    return ParseSymbol $expr
}

# Parses a chain of AND-connected terms.
#
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   $null on failure.
#
# Throws on any dangling operator.
function ParseAndChain {
    param ([String]$expr)
    [ParseResult]$left = ParseTerm $expr; if ($left) { $expr = $left.rem } else { return $null }
    [ParseResult]$comb = ParseAnd $expr; if ($comb) { $expr = $comb.rem } else { return $left }
    [ParseResult]$right = ParseAndChain $expr; if (-not $right) { throw "Expected Expression after '$($comb.val)'" }
    return [ParseResult]::New([PSCustomObject]@{
        term_type = [TermType]::Combination
        value = [PSCustomObject]@{
            left = $left.val; right = $right.val
            combine = [CmdbCombine]::And
        }
    }, $right.rem)
}

# Parses a chain of OR-connected terms.
# Uses `ParseAndChain` to handle precedence.
#
# Arguments:
#   [String]$expr - The input expression.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   $null on failure.
#
# Throws on any dangling operator.
function ParseTermChain {
    param ([String]$expr)
    [ParseResult]$left = ParseAndChain $expr; if ($left) { $expr = $left.rem } else { return $null }
    [ParseResult]$comb = ParseOr $expr; if ($comb) { $expr = $comb.rem } else { return $left }
    [ParseResult]$right = ParseTermChain $expr; if (-not $right) { throw "Expected Expression after '$($comb.val)'" }
    return [ParseResult]::New([PSCustomObject]@{
        term_type = [TermType]::Combination
        value = [PSCustomObject]@{
            left = $left.val; right = $right.val
            combine = [CmdbCombine]::Or
        }
    }, $right.rem)
}

# Parses an entire logic expression into a structured AST.
#
# Examples:
# ```.
# ParseExpression("location ~ RZ%").
# ParseExpression("age >= 30 AND (name = 'Alice' OR NOT (city = 'Paris'))").
# ````.
#
# Arguments:
#   [String]$string - The input expression to parse.
#
# Returns:
#   A structured `PSCustomObject` representing the parsed expression.
#
# Throws on any syntax errors.
function ParseExpression {
    param ([String]$expr)
    [ParseResult]$evaluated = ParseTermChain $expr
    if (-not $evaluated) { throw "Expected Expression" }
    [ParseResult]$trail = ParsePattern $evaluated.rem "^\s*(?<val>\S+)"
    if ($trail) { throw "Unexpected '$($trail.val)' after Expression" }
    return $evaluated.val
}


######################
# SECTION EVALUATION #
######################

# Checks if two term-nodes are equal.
#
# Arguments:
#   [`PSCustomObject`]$term_a - The first term.
#   [`PSCustomObject`]$term_b - The second term.
#
# Returns:
#   $true if the terms are equal or both $null.
#   $false otherwise.
function CompareTerms {
    param ([PSCustomObject]$term_a, [PSCustomObject]$term_b)
    if ($null -eq $term_a -and $null -eq $term_b) { return $true }
    if ($null -eq $term_a -or $null -eq $term_b) { return $false }
    if ($term_a.term_type -ne $term_b.term_type) { return $false }
    switch ($term_a.term_type) {
        ([TermType]::FlatCombination) {
            if ($term_a.value.combine -ne $term_b.value.combine) { return $false }
            if ($term_a.value.terms.Count -ne $term_b.value.terms.Count) { return $false }
            for ($i = 0; $i -lt $term_a.value.terms.Count; $i++) {
                if (CompareTerms $term_a.value.terms[$i] $term_b.value.terms[$i]) { continue }
                return $false
            }
            return $true
        }
        ([TermType]::Combination) {
            return $term_a.value.combine -eq $term_b.value.combine `
                -and (CompareTerms $term_a.value.left $term_b.value.left) `
                -and (CompareTerms $term_a.value.right $term_b.value.right)
        }
        ([TermType]::Comparison) {
            return $term_a.value.operator -eq $term_b.value.operator `
                -and $term_a.value.value -ceq $term_b.value.value `
                -and $term_a.value.field -eq $term_b.value.field
        }
        ([TermType]::Inversion) { return CompareTerms $term_a.value $term_b.value }
        ([TermType]::Boolean) { return $term_a.value -eq $term_b.value }
        ([TermType]::Symbol) { return $term_a.value -ceq $term_b.value }
    }
}

# Returns the logical inverse of a CmdbOperator.
#
# These are all operators and their inverses:
#   IsMatch      <=>  IsNotMatch.
#   IsEqual      <=>  IsNotEqual.
#   LessThan     <=>  GreaterThanOrEqual.
#   GreaterThan  <=>  LessThanOrEqual.
#
# Arguments:
#   [CmdbOperator]$operator - The input operator.
#
# Returns:
#   A CmdbOperator that is inverse to the input.
function InvertOperator {
    param ([CmdbOperator]$operator)
    switch ($operator) {
        ([CmdbOperator]::IsMatch)            { return [CmdbOperator]::IsNotMatch }
        ([CmdbOperator]::IsNotMatch)         { return [CmdbOperator]::IsMatch }
        ([CmdbOperator]::IsEqual)            { return [CmdbOperator]::IsNotEqual }
        ([CmdbOperator]::IsNotEqual)         { return [CmdbOperator]::IsEqual }
        ([CmdbOperator]::LessThan)           { return [CmdbOperator]::GreaterThanOrEqual }
        ([CmdbOperator]::LessThanOrEqual)    { return [CmdbOperator]::GreaterThan }
        ([CmdbOperator]::GreaterThan)        { return [CmdbOperator]::LessThanOrEqual }
        ([CmdbOperator]::GreaterThanOrEqual) { return [CmdbOperator]::LessThan }
    }
}

# Returns the logical inverse of a CmdbCombine.
# Input `And` returns `Or` and vice-versa.
#
# Arguments:
#   [CmdbCombine]$combine - The input combinator.
#
# Returns:
#   A CmdbCombine that is inverse to the input.
function InvertCombine {
    param ([CmdbCombine]$combine)
    switch ($combine) {
        ([CmdbCombine]::And) { return [CmdbCombine]::Or }
        ([CmdbCombine]::Or) { return [CmdbCombine]::And }
    }
}

# Returns the logical inverse of a term.
# Uses `InvertCombine` and `InvertOperator` as helper functions.
# Uses `NormalizeAST` to return a simplified value.
#
# Arguments:
#   [`PSCustomObject`]$node - The input term.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   The term is returned in normalized form.
function InvertTerm {
    param ([PSCustomObject]$node)
    switch ($node.term_type) {
        ([TermType]::Comparison)  {
            return [PSCustomObject]@{
                term_type = [TermType]::Comparison
                value = [PSCustomObject]@{
                    field = $node.value.field
                    value = $node.value.value
                    operator = InvertOperator $node.value.operator
                }
            }
        }
        ([TermType]::Combination) {
            return NormalizeAst ([PSCustomObject]@{
                term_type = [TermType]::Combination
                value = [PSCustomObject]@{
                    left = InvertTerm $node.value.left
                    right = InvertTerm $node.value.right
                    combine = InvertCombine $node.value.combine
                }
            })
        }
        ([TermType]::FlatCombination) {
            return FlattenCombination `
            -terms @($node.value.terms | ForEach-Object { InvertTerm $_ }) `
            -combine (InvertCombine $node.value.combine)
        }
        ([TermType]::Symbol) {
            return [PSCustomObject]@{ term_type = [TermType]::Inversion; value = $node }
        }
        ([TermType]::Boolean) { return BoolTerm (-not $node.value) }
        ([TermType]::Inversion) { return NormalizeAst $node.value }
    }
}

# Converts a Combination term into a FlatCombination.
# If any of the child terms are compatible FlatCombinations,
# they will also get desolved into the parent term.
#
# Arguments:
#   [`PSCustomObject`[]]$terms - The children terms.
#   [CmdbCombine]$combine - The combinator of the combination.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   - This Term is always a FlatCombination.
function FlattenCombination {
    param ([PSCustomObject[]]$terms, [CmdbCombine]$combine)
    [PSCustomObject]$short_circuit = BoolTerm ($combine -eq [CmdbCombine]::Or)
    [PSCustomObject]$neutral = InvertTerm $short_circuit
    [PSCustomObject[]]$unique = @()
    $terms = $terms | ForEach-Object {
        if ($_.term_type -eq [TermType]::FlatCombination -and $_.value.combine -eq $combine) `
        { $_.value.terms } else { $_ }
    }
    foreach ($term in $terms) {
        [Bool]$add = $true
        [PSCustomObject]$inverse = InvertTerm $term
        if (CompareTerms $term $short_circuit) { return $term }
        if (CompareTerms $term $neutral) { continue }
        foreach ($seen in $unique) {
            if (CompareTerms $inverse $seen) { return $short_circuit }
            if (CompareTerms $term $seen) { $add = $false; break }
        }
        if ($add) { $unique += $term }
    }
    if ($unique.Count -eq 0) { return $neutral }
    if ($unique.Count -eq 1) { return $unique[0] }
    return [PSCustomObject[]]@{
        term_type = [TermType]::FlatCombination
        value = [PSCustomObject]@{
            combine = $combine
            terms = $unique
        }
    }
}

# Distributes a term into a flat combination-term.
# Also normalizes and flattens the terms.
#
# Arguments:
#   [`PSCustomObject`]$term - The term that will get distributed.
#   [`PSCustomObject`]$into - The combination to distribute the term into.
#   [CmdbCombine]$combine - The combinator to join terms with.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   - This Term is always a FlatCombination.
function DistributeTerm {
    param ([PSCustomObject]$term, [PSCustomObject]$into, [CmdbCombine]$combine)
    return FlattenCombination -terms ($into.value.terms | ForEach-Object {
        NormalizeAst ([PSCustomObject]@{
            term_type = [TermType]::Combination
            value = [PSCustomObject]@{
                left = $_; right = $term
                combine = $combine
            }
        })
    }) -combine $into.value.combine
}

# Normalizes an entire logic-AST.
# Resolves all Inversions by applying DeMorgan's Law.
# Distributes And-combinations into child-Or-combinations.
# Flattens the tree into a single flat Or-Combination,
# that contains only flat And-Combinations (DNF).
# Eliminates redundant comparisons.
# Evaluates tautologies and oximora.
#
# Arguments:
#   [`PSCustomObject`]$node - The AST root term.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   - The term is returned in disjunctive normal form.
function NormalizeAst {
    param ([PSCustomObject]$node)
    switch ($node.term_type) {
        ([TermType]::Combination) {
            [PSCustomObject]$left = NormalizeAst $node.value.left
            [PSCustomObject]$right = NormalizeAst $node.value.right
            [CmdbCombine]$combine = $node.value.combine
            [Bool]$distribute = $combine -eq [CmdbCombine]::And
            [Bool]$left_comb = $left.term_type -eq [TermType]::FlatCombination
            [Bool]$right_comb = $right.term_type -eq [TermType]::FlatCombination
            [Bool]$distribute_left = $distribute -and $right_comb -and $right.value.combine -ne $combine
            [Bool]$distribute_right = $distribute -and $left_comb -and $left.value.combine -ne $combine
            if ($distribute_right) { return DistributeTerm -term $right -into $left -combine $combine }
            if ($distribute_left)  { return DistributeTerm -term $left -into $right -combine $combine }
            return FlattenCombination -terms @($left, $right) -combine $combine
        }
        ([TermType]::Inversion)       { return InvertTerm $node.value }
        ([TermType]::FlatCombination) { return $node } # Already Normalized.
        ([TermType]::Comparison)      { return $node }
        ([TermType]::Boolean)         { return $node }
        ([TermType]::Symbol)          { return $node }
    }
}


#####################
# SECTION INTERFACE #
#####################

# Converts a logical term into a readable string.
#
# Arguments:
#   [`PSCustomObject`]$node - The input term.
#
# Returns:
#   A String representing the term.
function RenderAst {
    param ([PSCustomObject]$node)
    switch ($node.term_type) {
        ([TermType]::Boolean) { return "$(if ($node.value) { "True" } else { "False" })" }
        ([TermType]::Inversion) { return "!$(RenderAst $node.value)" }
        ([TermType]::Symbol) { return $node.value }
        ([TermType]::Comparison) {
            return "$($node.value.field.ToUpper()) $(switch ($node.value.operator) {
                ([CmdbOperator]::IsMatch)            { "=~" }
                ([CmdbOperator]::IsNotMatch)         { "!~" }
                ([CmdbOperator]::IsEqual)            { "==" }
                ([CmdbOperator]::IsNotEqual)         { "!=" }
                ([CmdbOperator]::LessThan)           { "<"  }
                ([CmdbOperator]::LessThanOrEqual)    { "<=" }
                ([CmdbOperator]::GreaterThan)        { ">"  }
                ([CmdbOperator]::GreaterThanOrEqual) { ">=" }
            }) $($node.value.value | ConvertTo-Json)"
        }
        ([TermType]::Combination) {
            return "($(RenderAst $node.value.left)) $(switch ($node.value.combine) {
                ([CmdbCombine]::And) { "AND" }
                ([CmdbCombine]::Or)  { "OR" }
            }) ($(RenderAst $node.value.right))"
        }
        ([TermType]::FlatCombination) {
            [String]$combine = switch ($node.value.combine) {
                ([CmdbCombine]::And) { " & " }
                ([CmdbCombine]::Or)  { " | " }
            }
            return ($node.value.terms | ForEach-Object {
                RenderAst $_
            }) -join $combine
        }
    }
}

# Parses and normalizes a logic expression.
#
# Arguments:
#   [String]$expr - The input expression to parse.
#
# Returns:
#   A `PSCustomObject` with `term_type` and `value`.
#   - The term is returned in disjunctive normal form.
function EvaluateExpression {
    param ([String]$expr)
    return NormalizeAst (ParseExpression $expr)
}

# Turns a parsed logic tree into an array of CMDB parameters.
# Expects a normalized logic tree in disjunctive normal form.
# Booleans, Inversions and Symbols are not supported.
#
# Arguments:
#   [PSCustomObject]$node - The logic tree to convert.
#
# Optional Arguments:
#   [CmdbCombine]$combine - The top level `combine` value; defaults to AND.
#
# Returns:
#   An array of `CmdbParam` values, representing a CMDB query request.
#
# Throws:
#   On any unsupported terms: Booleans, Inversions, Symbols, (non-flat) Combinations.
function ConvertToParams {
    param ([PSCustomObject]$node, [CmdbCombine]$combine = [CmdbCombine]::And)
    switch ($node.term_type) {
        ([TermType]::Inversion) { throw "Expression includes an inversion, which is not supported" }
        ([TermType]::Symbol) { throw "Expression includes a symbol, which is not supported" }
        ([TermType]::Combination) { throw "Expression was not reduced apparently" }
        ([TermType]::Boolean) {
            if ($node.value) { throw "Expression reduced to 'True', which would return every value in the database" }
            else { throw "Expression reduced to 'False', which would not return any value" }
        }
        ([TermType]::Comparison) { return [CmdbParam]::New($node.value.field.ToUpper(), $node.value.value, $node.value.operator, $combine) }
        ([TermType]::FlatCombination) {
            return @(
                ConvertToParams $node.value.terms[0] $combine
                $node.value.terms[1..$node.value.terms.Count] | ForEach-Object { ConvertToParams $_ $node.value.combine }
            )
        }
    }
}
