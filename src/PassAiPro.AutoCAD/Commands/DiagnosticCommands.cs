using Autodesk.AutoCAD.Runtime;
using PassAiPro.Core.Diagnostics;
using CadApplication = Autodesk.AutoCAD.ApplicationServices.Core.Application;

namespace PassAiPro.AutoCAD.Commands
{
    public sealed class DiagnosticCommands
    {
        [CommandMethod("PASSAIPRO_ABOUT", CommandFlags.Modal)]
        public void About() => Write(DiagnosticReport.About());

        [CommandMethod("PASSAIPRO_STATUS", CommandFlags.Modal)]
        public void Status() => Write(DiagnosticReport.Status());

        private static void Write(string text)
        {
            var document = CadApplication.DocumentManager.MdiActiveDocument;
            if (document != null) document.Editor.WriteMessage("\n" + text + "\n");
        }
    }
}
