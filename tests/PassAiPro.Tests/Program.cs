using System;
using System.Collections.Generic;
using System.Linq;
using PassAiPro.Core;
using PassAiPro.Core.Diagnostics;
using PassAiPro.Core.Features;

namespace PassAiPro.Tests
{
    internal static class Program
    {
        private static int passed;
        private static int failed;

        private static void Check(string name, Action test)
        {
            try { test(); passed++; Console.WriteLine("PASS " + name); }
            catch (Exception ex) { failed++; Console.WriteLine("FAIL " + name + ": " + ex); }
        }
        private static void Require(bool condition) { if (!condition) throw new InvalidOperationException("Requirement not met."); }
        private static void Reject<T>(Action action) where T : Exception
        {
            try { action(); } catch (T) { return; }
            throw new InvalidOperationException("Expected " + typeof(T).Name);
        }

        private static int Main(string[] args)
        {
            if (args.Length != 1) { Console.Error.WriteLine("Expected version argument is required."); return 2; }
            Check("compiled version equals version.json", () => Require(ProductInfo.Version == args[0]));
            Check("product identity and host are explicit", () => Require(DiagnosticReport.About().Contains("PASS_AI_PRO " + args[0]) && DiagnosticReport.About().Contains("AutoCAD 2024")));
            Check("exact planned feature inventory", () => Require(FeatureCatalog.All.Select(x => x.Id).SequenceEqual(new[] { "MPL", "XBT" })));
            Check("planned features cannot appear implemented", () => Require(FeatureCatalog.All.All(x => x.State == FeatureState.Planned)));
            Check("status explains each missing feature", () => Require(DiagnosticReport.Status().Contains("MPL: 미구현 (후속 단계)") && DiagnosticReport.Status().Contains("XBT: 미구현 (후속 단계)")));
            Check("feature inventory resists caller mutation", () => Reject<NotSupportedException>(() => ((IList<FeatureDescriptor>)FeatureCatalog.All).Clear()));
            Check("blank feature ID rejected", () => Reject<ArgumentException>(() => new FeatureDescriptor(" ", "name", FeatureState.Planned)));
            Check("blank feature name rejected", () => Reject<ArgumentException>(() => new FeatureDescriptor("MPL", "", FeatureState.Planned)));
            Check("unknown feature state rejected", () => Reject<ArgumentOutOfRangeException>(() => new FeatureDescriptor("A", "name", (FeatureState)100)));
            Check("core has no CAD assembly dependency", () => Require(typeof(ProductInfo).Assembly.GetReferencedAssemblies().All(x => !x.Name!.StartsWith("Ac", StringComparison.Ordinal))));
            Console.WriteLine("RESULT " + passed + " passed, " + failed + " failed");
            return failed == 0 ? 0 : 1;
        }
    }
}
