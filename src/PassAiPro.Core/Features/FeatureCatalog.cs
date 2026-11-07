using System;
using System.Collections.Generic;

namespace PassAiPro.Core.Features
{
    public static class FeatureCatalog
    {
        public static IReadOnlyList<FeatureDescriptor> All { get; } = Array.AsReadOnly(new[]
        {
            new FeatureDescriptor("MPL", "다중 출력", FeatureState.Planned),
            new FeatureDescriptor("XBT", "XCLIP 경계 자르기·분해", FeatureState.Planned)
        });
    }
}
