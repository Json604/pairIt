using PairIt.Core;

internal static class UpdatePromptChecks
{
    internal static void Run()
    {
        var policy = new UpdatePromptPolicy();
        var now = DateTimeOffset.Parse("2026-11-15T00:00:00Z");
        void Check(bool ok) { if (!ok) throw new Exception("Update prompt policy regression"); }
        Check(!policy.TryPresent(null, now));
        Check(policy.TryPresent(25, now));
        Check(!policy.TryPresent(25, now.AddMinutes(1)));
        Check(!policy.TryPresent(26, now.AddMinutes(1))); // Never stack dialogs.
        policy.Dismiss();
        Check(!policy.TryPresent(25, now.AddHours(23)));
        Check(policy.TryPresent(26, now.AddHours(23))); // A genuinely newer release.
        policy.Dismiss();
        Check(!policy.TryPresent(25, now.AddHours(25))); // Never regress to stale cached feed.
        Check(policy.TryPresent(26, now.AddHours(47)));
        policy.Dismiss();
        Check(new UpdatePromptPolicy().TryPresent(26, now)); // New process checks again.
    }
}
