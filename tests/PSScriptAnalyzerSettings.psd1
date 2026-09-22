@{
    # Reglas por defecto, menos las que no aplican a este proyecto.
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # Write-Host es intencional: la salida de este gestor es una interfaz
        # de consola para una persona, no objetos para la tuberia.
        'PSAvoidUsingWriteHost',

        # El gestor es interactivo por diseño: pregunta antes de instalar con
        # winget y antes de borrar. Esas confirmaciones usan Read-Host.
        'PSAvoidUsingReadHost',

        # Los comandos son verbos de dominio (setup, probe, doctor) expuestos
        # por comodo.ps1, no cmdlets destinados a la tuberia de PowerShell.
        'PSUseShouldProcessForStateChangingFunctions',

        # Reglas de estilo informativas. Anadir [OutputType()] y bloques de
        # ayuda a cada funcion auxiliar interna generaria mas ruido que valor;
        # las funciones publicas ya llevan comentario de ayuda.
        'PSUseOutputTypeCorrectly',
        'PSProvideCommentHelp',

        # 'Invoke-PreRequisites' y 'Get-SupportedCudaVersion(es)' devuelven
        # colecciones y el plural es el nombre natural del dominio.
        'PSUseSingularNouns',

        # Las variables de color son superficie exportada del modulo
        # (Export-ModuleMember -Variable): el analizador solo mira el archivo
        # que las define y no ve su uso en los modulos que las importan.
        'PSUseDeclaredVarsMoreThanAssignments'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable        = $true
            TargetVersions = @('7.0')
        }
    }
}
