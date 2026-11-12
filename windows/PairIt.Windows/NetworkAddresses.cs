using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace PairIt.Windows;

internal sealed record LocalAddress(string Host, string Interface)
{
    public override string ToString() => $"{Host} · {Interface}";
}

internal static class NetworkAddresses
{
    public static IReadOnlyList<LocalAddress> List() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up && adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback)
        .SelectMany(adapter => adapter.GetIPProperties().UnicastAddresses
            .Where(address => address.Address.AddressFamily == AddressFamily.InterNetwork)
            .Select(address => new LocalAddress(address.Address.ToString(), adapter.Name)))
        .OrderBy(address => address.Interface, StringComparer.CurrentCultureIgnoreCase).ToArray();
}
