using System.Reflection;

namespace PassAiPro.Core
{
    public static class ProductInfo
    {
        public const string Name = "PASS_AI_PRO";
        public const string SupportedHost = "AutoCAD 2024 / Windows x64";
        public static string Version => typeof(ProductInfo).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion;
    }
}
