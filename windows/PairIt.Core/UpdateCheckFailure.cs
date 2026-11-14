using System.Net.Http;
using System.Text.Json;

namespace PairIt.Core;

/// Safe, actionable update errors. Never display exception text, proxy addresses or credentials.
public static class UpdateCheckFailure
{
    public static string Describe(Exception error) => error switch
    {
        JsonException or InvalidDataException or KeyNotFoundException or InvalidOperationException
            => "Update information is invalid. Please try again later.",
        OperationCanceledException => "Update check timed out. Please try again.",
        HttpRequestException { StatusCode: { } status }
            => $"Update service returned HTTP {(int)status}. Please try again later.",
        HttpRequestException { HttpRequestError: HttpRequestError.SecureConnectionError }
            => "Couldn’t verify the update service certificate. Check your system date and trusted certificates.",
        HttpRequestException { HttpRequestError: HttpRequestError.NameResolutionError }
            => "Couldn’t resolve the update service address. Check your DNS or VPN settings.",
        HttpRequestException { HttpRequestError: HttpRequestError.ProxyTunnelError }
            => "The proxy couldn’t reach the update service. Check your proxy settings.",
        HttpRequestException => "Couldn’t reach the update service. Check your network or VPN and retry.",
        _ => "Update check failed. Please try again later."
    };
}
