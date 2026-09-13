<#
  Pester tests for the Compare-SPListSchema diff engine.
  Run:  Invoke-Pester -Path .\Tests
  The script is dot-sourced, so its main block is skipped (see the InvocationName guard)
  and only the functions are loaded for testing.
#>

BeforeAll {
  . "$PSScriptRoot\..\Compare-SPListSchema.ps1"

  function NewField {
    param(
      [string]$Name, [string]$Type = 'Text', [bool]$Required = $false,
      [string[]]$Choices = @(), [string]$Lookup = $null, [bool]$Indexed = $false,
      [string]$Formula = $null
    )
    [pscustomobject]@{
      internalName = $Name; displayName = $Name; type = $Type; required = $Required
      choices = $Choices; lookupTarget = $Lookup; lookupField = $(if ($Lookup) { 'Title' } else { $null })
      formula = $Formula; default = ''; indexed = $Indexed
    }
  }
  function NewList { param([string]$Title, $Fields) [pscustomobject]@{ title = $Title; url = "/Lists/$Title"; template = 100; fields = @($Fields) } }
  function NewSnap { param([string]$Site, $Lists) [pscustomobject]@{ site = $Site; extracted = 'x'; lists = @($Lists) } }
}

Describe 'Compare-Schema' {

  It 'reports in sync for identical schemas' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A'), (NewField 'B' 'Number') ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A'), (NewField 'B' 'Number') ) )
    $d = Compare-Schema -Source $a -Target $b
    $d.inSync | Should -BeTrue
    @($d.listsChanged).Count | Should -Be 0
  }

  It 'ignores field order (matches by internal name, not position)' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A'), (NewField 'B') ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'B'), (NewField 'A') ) )
    (Compare-Schema -Source $a -Target $b).inSync | Should -BeTrue
  }

  It 'detects a column added on the target' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A') ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A'), (NewField 'C') ) )
    $d = Compare-Schema -Source $a -Target $b
    $d.inSync | Should -BeFalse
    $d.listsChanged[0].fieldsOnlyInTarget | Should -Contain 'C'
  }

  It 'detects a column removed on the target' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A'), (NewField 'C') ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A') ) )
    (Compare-Schema -Source $a -Target $b).listsChanged[0].fieldsOnlyInSource | Should -Contain 'C'
  }

  It 'detects a Required change' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A' 'Currency' $true) ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A' 'Currency' $false) ) )
    $chg = (Compare-Schema -Source $a -Target $b).listsChanged[0].fieldsChanged
    $chg[0].field | Should -Be 'A'
    ($chg[0].changes | Where-Object property -eq 'required').source | Should -Be 'True'
    ($chg[0].changes | Where-Object property -eq 'required').target | Should -Be 'False'
  }

  It 'detects a choices change' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A' 'Choice' $false @('X','Y')) ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A' 'Choice' $false @('X','Y','Z')) ) )
    $chg = (Compare-Schema -Source $a -Target $b).listsChanged[0].fieldsChanged
    ($chg[0].changes | Where-Object property -eq 'choices') | Should -Not -BeNullOrEmpty
  }

  It 'detects a lookup target change (by title)' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A' 'Lookup' $false @() 'Employees') ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A' 'Lookup' $false @() 'Teams') ) )
    $chg = (Compare-Schema -Source $a -Target $b).listsChanged[0].fieldsChanged
    ($chg[0].changes | Where-Object property -eq 'lookupTarget').target | Should -Be 'Teams'
  }

  It 'detects a type change' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A' 'Text') ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A' 'Note') ) )
    $chg = (Compare-Schema -Source $a -Target $b).listsChanged[0].fieldsChanged
    ($chg[0].changes | Where-Object property -eq 'type').target | Should -Be 'Note'
  }

  It 'detects a list only in the target' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A') ) )
    $b = NewSnap 'prod' @( (NewList 'L1' @( (NewField 'A') )), (NewList 'L2' @( (NewField 'X') )) )
    (Compare-Schema -Source $a -Target $b).listsOnlyInTarget | Should -Contain 'L2'
  }

  It 'detects a list only in the source' {
    $a = NewSnap 'dev'  @( (NewList 'L1' @( (NewField 'A') )), (NewList 'L2' @( (NewField 'X') )) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A') ) )
    (Compare-Schema -Source $a -Target $b).listsOnlyInSource | Should -Contain 'L2'
  }

  It 'produces no false positive when only display names differ but the model matches' {
    $a = NewSnap 'dev'  @( NewList 'L1' @( (NewField 'A' 'Number' $false @() $null $true) ) )
    $b = NewSnap 'prod' @( NewList 'L1' @( (NewField 'A' 'Number' $false @() $null $true) ) )
    (Compare-Schema -Source $a -Target $b).inSync | Should -BeTrue
  }
}

Describe 'Get-FieldSig' {
  It 'renders "not present" for a missing field' {
    Get-FieldSig -Field $null -Enc { param($s) $s } | Should -Match 'not present'
  }
  It 'highlights only the differing property' {
    $enc = { param($s) $s }
    $f = NewField 'A' 'Currency' $true
    (Get-FieldSig -Field $f -Enc $enc -DiffProps @('required')) | Should -Match "<b class='hl'>required</b>"
    (Get-FieldSig -Field $f -Enc $enc -DiffProps @('required')) | Should -Not -Match "<b class='hl'>Currency</b>"
  }
}
