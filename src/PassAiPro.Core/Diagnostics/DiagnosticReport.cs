using System;
using System.Text;
using PassAiPro.Core.Features;

namespace PassAiPro.Core.Diagnostics
{
    public static class DiagnosticReport
    {
        public static string About() => ProductInfo.Name + " " + ProductInfo.Version + Environment.NewLine + ProductInfo.SupportedHost;

        public static string Status()
        {
            var text = new StringBuilder(About());
            text.AppendLine().Append("프로그램 뼈대: 진단 명령 사용 가능");
            foreach (var feature in FeatureCatalog.All)
                text.AppendLine().Append(feature.Id).Append(": ")
                    .Append(feature.State == FeatureState.Available ? "사용 가능" : "미구현 (후속 단계)");
            return text.ToString();
        }
    }
}
