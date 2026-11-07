using Autodesk.AutoCAD.Runtime;

[assembly: ExtensionApplication(typeof(PassAiPro.AutoCAD.ExtensionApplication))]
[assembly: CommandClass(typeof(PassAiPro.AutoCAD.Commands.DiagnosticCommands))]

namespace PassAiPro.AutoCAD
{
    public sealed class ExtensionApplication : IExtensionApplication
    {
        public void Initialize() { }
        public void Terminate() { }
    }
}
