using System;

namespace PassAiPro.Core.Features
{
    public enum FeatureState { Planned, Available }

    public sealed class FeatureDescriptor
    {
        public string Id { get; }
        public string Name { get; }
        public FeatureState State { get; }

        public FeatureDescriptor(string id, string name, FeatureState state)
        {
            if (string.IsNullOrWhiteSpace(id)) throw new ArgumentException("Feature ID is required.", nameof(id));
            if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Feature name is required.", nameof(name));
            if (!Enum.IsDefined(typeof(FeatureState), state)) throw new ArgumentOutOfRangeException(nameof(state));
            Id = id;
            Name = name;
            State = state;
        }
    }
}
