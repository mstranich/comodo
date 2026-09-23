BeforeAll {
    $script:Entry = Join-Path (Split-Path $PSScriptRoot -Parent) 'comodo.ps1'

    # Patrones del switch principal. Se exige la indentacion exacta de ese
    # switch (8 espacios): los switch anidados de los subcomandos usan la
    # misma forma y colarian 'set', 'list', etc. como si fueran comandos.
    $script:Patterns = @(
        Get-Content -LiteralPath $script:Entry -Encoding UTF8 |
            ForEach-Object {
                if ($_ -match "^ {8}'(\^\([^']+\)\`$)'\s*\{") { $Matches[1] }
            }
    )

    # Alias sueltos que contiene cada patron, para poder probarlos uno a uno.
    $script:Aliases = @(
        $script:Patterns | ForEach-Object {
            if ($_ -match '^\^\((.+)\)\$$') {
                $Matches[1] -split '\|'
            }
        } | ForEach-Object { $_ -replace '\\', '' } |
            Where-Object { $_ -and $_ -notmatch '[\[\]\?\*\+]' }
    )
}

Describe 'Comandos de comodo.ps1' {
    It 'se extrajeron patrones del switch' {
        $script:Patterns.Count | Should -BeGreaterThan 8
    }

    # Regresion: 'switch -Regex' de PowerShell ejecuta TODAS las ramas que
    # coinciden, no solo la primera. 'install' era a la vez alias de 'setup' y
    # nombre del nuevo espacio, asi que 'install list' ejecutaba un setup
    # completo antes de mostrar la lista.
    It 'ningun alias coincide con mas de un patron' {
        foreach ($alias in $script:Aliases) {
            $hits = @($script:Patterns | Where-Object { $alias -match $_ })
            $hits.Count | Should -Be 1 -Because "'$alias' coincide con: $($hits -join '  ')"
        }
    }

    It 'los espacios de ajustes estan separados' {
        $script:Aliases | Should -Contain 'flag'
        $script:Aliases | Should -Contain 'provision'
        $script:Aliases | Should -Contain 'manager'
    }

    # 'install' se conserva como atajo de 'provision apply'; 'setup' se
    # elimino para no tener dos nombres para la misma accion.
    It 'install sigue existiendo y setup ya no' {
        $script:Aliases | Should -Contain 'install'
        $script:Aliases | Should -Not -Contain 'setup'
    }

    # Corte limpio acordado: 'set' y 'unset' sueltos ya no existen como
    # comandos de primer nivel, solo como subcomandos de cada espacio.
    It 'set y unset ya no son comandos de primer nivel' {
        $script:Aliases | Should -Not -Contain 'set'
        $script:Aliases | Should -Not -Contain 'unset'
    }
}
