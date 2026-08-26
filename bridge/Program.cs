using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;

const string Protocol = "VOTVCOOP1";

AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
{
    var message = $"{DateTimeOffset.Now:O}\n{eventArgs.ExceptionObject}\n";
    try { File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "VotVCoopBridge-crash.log"), message); }
    catch { }
};

if (args.Length == 0 || args.Contains("--help"))
{
    Console.WriteLine("VotVCoopBridge --role host|client --bridge <folder> [--host 127.0.0.1] [--port 27071] [--name Player]");
    return;
}

string Get(string key, string fallback)
{
    var index = Array.IndexOf(args, key);
    return index >= 0 && index + 1 < args.Length ? args[index + 1] : fallback;
}

var role = Get("--role", "client").ToLowerInvariant();
var bridgeDirectory = Path.GetFullPath(Get("--bridge", "."));
var remoteHost = Get("--host", "127.0.0.1");
if (!int.TryParse(Get("--port", "27071"), CultureInfo.InvariantCulture, out var port) || port is < 1 or > 65535)
{
    Console.Error.WriteLine("Ошибка: --port должен быть числом от 1 до 65535.");
    return;
}
var playerName = Get("--name", Environment.MachineName).Replace('|', '_');

if (role is not ("host" or "client"))
    throw new ArgumentException("--role must be host or client");

Directory.CreateDirectory(bridgeDirectory);
var localStatePath = Path.Combine(bridgeDirectory, "local_state.txt");
var remoteStatePath = Path.Combine(bridgeDirectory, "remote_state.txt");
var statusPath = Path.Combine(bridgeDirectory, "status.txt");

using var udp = new UdpClient(role == "host" ? port : 0);
udp.Client.ReceiveTimeout = 50;
var serverEndpoint = role == "client"
    ? new IPEndPoint((await Dns.GetHostAddressesAsync(remoteHost)).First(x => x.AddressFamily == AddressFamily.InterNetwork), port)
    : null;
IPEndPoint? peer = serverEndpoint;

Console.WriteLine($"VotV Coop bridge: {role}, UDP {port}, bridge={bridgeDirectory}");
WriteAtomic(statusPath, $"starting|{role}|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");

long lastSequence = -1;
long lastHello = 0;
long lastPeerPacket = 0;
long lastTelemetry = 0;
string? peerName = null;
double remoteX = 0, remoteY = 0, remoteZ = 0;
bool hasRemoteState = false;
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };

while (!cancellation.IsCancellationRequested)
{
    var now = Environment.TickCount64;
    if (role == "client" && peer != null && now - lastHello > 1000)
    {
        Send(udp, peer, $"{Protocol}|HELLO|{playerName}");
        lastHello = now;
    }

    try
    {
        while (udp.Available > 0)
        {
            var source = new IPEndPoint(IPAddress.Any, 0);
            var packet = Encoding.UTF8.GetString(udp.Receive(ref source));
            var fields = packet.Split('|');
            if (fields.Length < 2 || fields[0] != Protocol) continue;

            if (role == "host" && fields[1] == "HELLO")
            {
                peer = source;
                Send(udp, peer, $"{Protocol}|WELCOME|{playerName}");
                lastPeerPacket = now;
                Console.WriteLine($"Peer connected: {source}");
            }
            else if (fields[1] == "WELCOME")
            {
                peer = source;
                lastPeerPacket = now;
            }
            else if (fields[1] == "STATE" && fields.Length >= 8)
            {
                lastPeerPacket = now;
                peerName = fields[2];
                hasRemoteState = double.TryParse(fields[4], NumberStyles.Float, CultureInfo.InvariantCulture, out remoteX)
                    && double.TryParse(fields[5], NumberStyles.Float, CultureInfo.InvariantCulture, out remoteY)
                    && double.TryParse(fields[6], NumberStyles.Float, CultureInfo.InvariantCulture, out remoteZ);
                WriteAtomic(remoteStatePath, string.Join('|', fields.Skip(2)));
            }
        }
    }
    catch (SocketException) { }

    if (peer != null && TryReadState(localStatePath, out var state, out var sequence) && sequence != lastSequence)
    {
        Send(udp, peer, $"{Protocol}|STATE|{playerName}|{state}");
        lastSequence = sequence;
    }

    var connected = peer != null && lastPeerPacket != 0 && now - lastPeerPacket < 5000;
    WriteAtomic(statusPath, $"{(connected ? "connected" : "waiting")}|{role}|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
    if (connected && hasRemoteState && peerName != null && now - lastTelemetry >= 1000
        && TryReadPosition(localStatePath, out var localX, out var localY, out var localZ))
    {
        var dx = remoteX - localX;
        var dy = remoteY - localY;
        var dz = remoteZ - localZ;
        var distanceMeters = Math.Sqrt(dx * dx + dy * dy + dz * dz) / 100.0;
        Console.WriteLine(string.Create(CultureInfo.InvariantCulture,
            $"CONNECTED peer={peerName} pos=({remoteX:F1},{remoteY:F1},{remoteZ:F1}) distance={distanceMeters:F1}m"));
        lastTelemetry = now;
    }
    await Task.Delay(25, cancellation.Token).ConfigureAwait(false);
}

static void Send(UdpClient udp, IPEndPoint endpoint, string value)
{
    var bytes = Encoding.UTF8.GetBytes(value);
    udp.Send(bytes, bytes.Length, endpoint);
}

static bool TryReadState(string path, out string payload, out long sequence)
{
    payload = "";
    sequence = -1;
    try
    {
        if (!File.Exists(path)) return false;
        var value = File.ReadAllText(path).Trim();
        var separator = value.IndexOf('|');
        if (separator < 1 || !long.TryParse(value[..separator], out sequence)) return false;
        payload = value;
        return true;
    }
    catch (IOException) { return false; }
    catch (UnauthorizedAccessException) { return false; }
}

static bool TryReadPosition(string path, out double x, out double y, out double z)
{
    x = y = z = 0;
    try
    {
        if (!File.Exists(path)) return false;
        var fields = File.ReadAllText(path).Trim().Split('|');
        return fields.Length >= 4
            && double.TryParse(fields[1], NumberStyles.Float, CultureInfo.InvariantCulture, out x)
            && double.TryParse(fields[2], NumberStyles.Float, CultureInfo.InvariantCulture, out y)
            && double.TryParse(fields[3], NumberStyles.Float, CultureInfo.InvariantCulture, out z);
    }
    catch (IOException) { return false; }
    catch (UnauthorizedAccessException) { return false; }
}

static void WriteAtomic(string path, string value)
{
    var temporary = path + ".tmp";
    try
    {
        File.WriteAllText(temporary, value, Encoding.UTF8);
        File.Move(temporary, path, true);
    }
    catch (IOException) { }
    catch (UnauthorizedAccessException) { }
}
