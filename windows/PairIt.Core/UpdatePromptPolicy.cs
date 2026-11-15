namespace PairIt.Core;

/// Process-local reminders: once at launch, then daily, never stacked.
public sealed class UpdatePromptPolicy
{
    private int lastBuild;
    private DateTimeOffset lastShown = DateTimeOffset.MinValue;
    private bool showing;

    public bool TryPresent(int? build, DateTimeOffset now)
    {
        if (showing || build is not > 0 || build < lastBuild) return false;
        if (build == lastBuild && now - lastShown < TimeSpan.FromDays(1)) return false;
        lastBuild = build.Value;
        lastShown = now;
        showing = true;
        return true;
    }

    public void Dismiss() => showing = false;
}
