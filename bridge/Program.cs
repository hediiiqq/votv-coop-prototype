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

var staleTimeoutMsStr = Get("--stale-local-state-ms", "12000");
if (!int.TryParse(staleTimeoutMsStr, CultureInfo.InvariantCulture, out var staleTimeoutMs) || staleTimeoutMs <= 0)
{
    staleTimeoutMs = 12000;
}

var maxRetryAttemptsStr = Get("--max-retry-attempts", "25");
if (!int.TryParse(maxRetryAttemptsStr, CultureInfo.InvariantCulture, out var maxRetryAttempts) || maxRetryAttempts <= 0)
{
    maxRetryAttempts = 25;
}

Directory.CreateDirectory(bridgeDirectory);
var localStatePath = Path.Combine(bridgeDirectory, "local_state.txt");
var remoteStatePath = Path.Combine(bridgeDirectory, "remote_state.txt");
var localActionPath = Path.Combine(bridgeDirectory, "local_action.txt");
var remoteActionPath = Path.Combine(bridgeDirectory, "remote_action.txt");
var localInteractPath = Path.Combine(bridgeDirectory, "local_interact.txt");
var remoteInteractPath = Path.Combine(bridgeDirectory, "remote_interact.txt");
var localWorldStatePath = Path.Combine(bridgeDirectory, "local_world_state.txt");
var remoteWorldStatePath = Path.Combine(bridgeDirectory, "remote_world_state.txt");
var statusPath = Path.Combine(bridgeDirectory, "status.txt");

UdpClient udp;
try
{
    udp = new UdpClient(role == "host" ? port : 0);
}
catch (SocketException ex)
{
    var errorMessage = $"Failed to bind UDP port {port} ({ex.SocketErrorCode}): {ex.Message}";
    Console.Error.WriteLine($"Error: {errorMessage}");
    WriteAtomic(statusPath, $"error|bind_failed|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
    return;
}

using (udp)
{
    udp.Client.ReceiveTimeout = 50;

    IPEndPoint? serverEndpoint = null;
    if (role == "client")
    {
        try
        {
            var addresses = await Dns.GetHostAddressesAsync(remoteHost).ConfigureAwait(false);
            var ipv4 = addresses.FirstOrDefault(x => x.AddressFamily == AddressFamily.InterNetwork);
            if (ipv4 == null)
            {
                Console.Error.WriteLine($"Error: Could not resolve IPv4 address for host {remoteHost}");
                WriteAtomic(statusPath, $"error|dns_resolve_failed|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
                return;
            }
            serverEndpoint = new IPEndPoint(ipv4, port);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Error: Failed to resolve host {remoteHost}: {ex.Message}");
            WriteAtomic(statusPath, $"error|dns_resolve_failed|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
            return;
        }
    }

    IPEndPoint? peer = serverEndpoint;

    Console.WriteLine($"VotV Coop bridge: {role}, UDP {port}, bridge={bridgeDirectory}");
    WriteAtomic(statusPath, $"starting|{role}|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");

    var bridgeStartTime = DateTime.UtcNow;
    bool hasObservedLocalState = false;
    long lastLocalStateSeenTick = 0;
    DateTime lastLocalStateFileWriteUtc = DateTime.MinValue;
    long lastLocalSequenceSeen = -1;

    long lastSequence = -1;
    long lastActionSequence = -1;
    long lastLocalInteractSequence = -1;
    long lastLocalWorldSequence = -1;

    long lastHello = 0;
    long lastPeerPacket = 0;
    long lastTelemetry = 0;
    string? peerName = null;
    double remoteX = 0, remoteY = 0, remoteZ = 0;
    bool hasRemoteState = false;

    // Host-side world state cache: objectId -> (statePayload, sequence)
    var worldCache = new Dictionary<string, (string state, long seq)>();

    // Reliable delivery retry queue
    var pendingReliablePackets = new List<PendingReliablePacket>();

    // Deduplication sets & version trackers (bounded sliding window sets)
    var processedInteractSeqs = new SlidingSet<long>(2048);
    var processedWorldSeqs = new SlidingSet<long>(2048);
    var objectLatestSeq = new Dictionary<string, long>();
    string? lastError = null;

    const int maxLogBufferSize = 1024;
    var remoteInteractsBuffer = new List<string>();
    var remoteWorldStatesBuffer = new List<string>();

    void SendReliable(string type, long sequence, string rawPacket, long currentTick)
    {
        if (peer != null)
        {
            Send(udp, peer, rawPacket);
        }
        if (!pendingReliablePackets.Any(p => p.Type == type && p.Sequence == sequence))
        {
            pendingReliablePackets.Add(new PendingReliablePacket
            {
                Type = type,
                Sequence = sequence,
                RawPacket = rawPacket,
                LastSentTick = currentTick,
                AttemptCount = 1,
                MaxAttempts = maxRetryAttempts,
                RetryIntervalMs = 100
            });
        }
    }

    using var cancellation = new CancellationTokenSource();
    Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };

    while (!cancellation.IsCancellationRequested)
    {
        var now = Environment.TickCount64;

        if (File.Exists(localStatePath))
        {
            try
            {
                var writeTime = File.GetLastWriteTimeUtc(localStatePath);
                if (TryReadState(localStatePath, out var _, out var localSeq))
                {
                    if (!hasObservedLocalState)
                    {
                        if (writeTime >= bridgeStartTime.AddSeconds(-2) || (lastLocalSequenceSeen != -1 && localSeq != lastLocalSequenceSeen))
                        {
                            hasObservedLocalState = true;
                            lastLocalStateSeenTick = now;
                            lastLocalStateFileWriteUtc = writeTime;
                        }
                        lastLocalSequenceSeen = localSeq;
                    }
                    else
                    {
                        if (localSeq != lastLocalSequenceSeen || writeTime != lastLocalStateFileWriteUtc)
                        {
                            lastLocalSequenceSeen = localSeq;
                            lastLocalStateFileWriteUtc = writeTime;
                            lastLocalStateSeenTick = now;
                        }
                    }
                }
            }
            catch { }
        }

        if (hasObservedLocalState && (now - lastLocalStateSeenTick > staleTimeoutMs))
        {
            Console.WriteLine($"Local state became stale (no updates for {staleTimeoutMs}ms). Exiting bridge gracefully.");
            WriteAtomic(statusPath, $"stopped|stale_game|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
            break;
        }

        if (role == "client" && peer != null && now - lastHello > 1000)
        {
            Send(udp, peer, $"{Protocol}|HELLO|{playerName}");
            lastHello = now;
        }

        bool hasNewInteracts = false;
        bool hasNewWorldStates = false;

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
                    bool isNewConnection = peer == null || !peer.Equals(source) || (lastPeerPacket != 0 && now - lastPeerPacket > 4000);
                    peer = source;
                    Send(udp, peer, $"{Protocol}|WELCOME|{playerName}");
                    lastPeerPacket = now;
                    Console.WriteLine($"Peer connected: {source}");

                    if (isNewConnection)
                    {
                        processedInteractSeqs.Clear();
                        remoteInteractsBuffer.Clear();
                        lastError = null;
                        pendingReliablePackets.RemoveAll(p => p.Type == "STATE");
                        foreach (var kvp in worldCache)
                        {
                            var objId = kvp.Key;
                            var (cachedState, cachedSeq) = kvp.Value;
                            var snapshotPacket = $"{Protocol}|WORLD_STATE|{cachedSeq}|{playerName}|{objId}|{cachedState}";
                            SendReliable("STATE", cachedSeq, snapshotPacket, now);
                            Console.WriteLine($"WORLD_STATE snapshot sent #{cachedSeq}: {objId} = {cachedState}");
                        }
                    }
                }
                else if (fields[1] == "WELCOME")
                {
                    bool isNewConnection = peer == null || !peer.Equals(source) || (lastPeerPacket != 0 && now - lastPeerPacket > 4000);
                    peer = source;
                    lastPeerPacket = now;
                    if (isNewConnection)
                    {
                        processedWorldSeqs.Clear();
                        objectLatestSeq.Clear();
                        remoteWorldStatesBuffer.Clear();
                        lastError = null;
                        Console.WriteLine($"Connected to host: {source}, session state reset.");
                    }
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
                else if (fields[1] == "ACTION" && fields.Length >= 9)
                {
                    lastPeerPacket = now;
                    var actionPayload = string.Join('|', fields.Skip(2));
                    WriteAtomic(remoteActionPath, actionPayload);
                    Console.WriteLine($"ACTION received from {fields[2]}: {actionPayload}");
                }
                else if (fields[1] == "INTERACT_REQ" && fields.Length >= 6)
                {
                    lastPeerPacket = now;
                    if (long.TryParse(fields[2], out var reqSeq))
                    {
                        var senderName = fields[3];
                        var objectId = fields[4];
                        var actionPayload = string.Join('|', fields.Skip(5));

                        // Always send ACK back to sender immediately (even if duplicate)
                        Send(udp, source, $"{Protocol}|WORLD_ACK|REQ|{reqSeq}|{playerName}");

                        if (role == "host")
                        {
                            if (processedInteractSeqs.Add(reqSeq))
                            {
                                var payload = $"{senderName}|{reqSeq}|{objectId}|{actionPayload}";
                                remoteInteractsBuffer.Add(payload);
                                if (remoteInteractsBuffer.Count > maxLogBufferSize)
                                {
                                    remoteInteractsBuffer.RemoveRange(0, remoteInteractsBuffer.Count - maxLogBufferSize);
                                }
                                hasNewInteracts = true;
                                Console.WriteLine($"INTERACT_REQ received from {senderName}: #{reqSeq} {objectId} -> {actionPayload}");
                            }
                            else
                            {
                                Console.WriteLine($"INTERACT_REQ duplicate ignored #{reqSeq} from {senderName}");
                            }
                        }
                        else
                        {
                            Console.WriteLine($"INTERACT_REQ ignored: receiver is {role}, not host");
                        }
                    }
                }
                else if (fields[1] == "WORLD_STATE" && fields.Length >= 6)
                {
                    lastPeerPacket = now;
                    if (long.TryParse(fields[2], out var stateSeq))
                    {
                        var hostSender = fields[3];
                        var objectId = fields[4];
                        var statePayload = string.Join('|', fields.Skip(5));

                        // Always send ACK back to host sender immediately
                        Send(udp, source, $"{Protocol}|WORLD_ACK|STATE|{stateSeq}|{playerName}");

                        if (role == "client")
                        {
                            if (objectLatestSeq.TryGetValue(objectId, out var lastSeq) && stateSeq < lastSeq)
                            {
                                Console.WriteLine($"WORLD_STATE outdated ignored #{stateSeq} for {objectId} (current #{lastSeq})");
                            }
                            else if (objectLatestSeq.TryGetValue(objectId, out var currentSeq) && stateSeq == currentSeq)
                            {
                                Console.WriteLine($"WORLD_STATE duplicate ignored #{stateSeq} from {hostSender}");
                            }
                            else
                            {
                                processedWorldSeqs.Add(stateSeq);
                                objectLatestSeq[objectId] = stateSeq;
                                var payload = $"{hostSender}|{stateSeq}|{objectId}|{statePayload}";
                                remoteWorldStatesBuffer.Add(payload);
                                if (remoteWorldStatesBuffer.Count > maxLogBufferSize)
                                {
                                    remoteWorldStatesBuffer.RemoveRange(0, remoteWorldStatesBuffer.Count - maxLogBufferSize);
                                }
                                hasNewWorldStates = true;
                                Console.WriteLine($"WORLD_STATE received from {hostSender}: #{stateSeq} {objectId} = {statePayload}");
                            }
                        }
                        else
                        {
                            Console.WriteLine($"WORLD_STATE ignored from {hostSender}: host ignores remote WORLD_STATE");
                        }
                    }
                }
                else if (fields[1] == "WORLD_ACK" && fields.Length >= 4)
                {
                    lastPeerPacket = now;
                    var ackType = fields[2].ToUpperInvariant();
                    if (ackType == "INTERACT_REQ") ackType = "REQ";
                    if (ackType == "WORLD_STATE") ackType = "STATE";
                    if (long.TryParse(fields[3], out var ackSeq))
                    {
                        var removed = pendingReliablePackets.RemoveAll(p => p.Type == ackType && p.Sequence == ackSeq);
                        if (removed > 0)
                        {
                            Console.WriteLine($"WORLD_ACK received for {ackType} #{ackSeq}");
                        }
                    }
                }
            }
        }
        catch (SocketException) { }

        if (hasNewInteracts)
        {
            WriteAtomic(remoteInteractPath, string.Join("\n", remoteInteractsBuffer));
        }

        if (hasNewWorldStates)
        {
            WriteAtomic(remoteWorldStatePath, string.Join("\n", remoteWorldStatesBuffer));
        }

        if (peer != null && TryReadState(localStatePath, out var state, out var sequence) && sequence != lastSequence)
        {
            Send(udp, peer, $"{Protocol}|STATE|{playerName}|{state}");
            lastSequence = sequence;
        }

        if (peer != null && TryReadAction(localActionPath, out var action, out var actionSequence) && actionSequence != lastActionSequence)
        {
            Send(udp, peer, $"{Protocol}|ACTION|{playerName}|{action}");
            lastActionSequence = actionSequence;
            Console.WriteLine($"ACTION sent #{actionSequence}: {action}");
        }

        if (role == "client" && TryReadInteracts(localInteractPath, out var interacts, out var _))
        {
            foreach (var item in interacts)
            {
                if (item.seq > lastLocalInteractSequence)
                {
                    var packet = $"{Protocol}|INTERACT_REQ|{item.seq}|{playerName}|{item.objId}|{item.action}";
                    SendReliable("REQ", item.seq, packet, now);
                    lastLocalInteractSequence = Math.Max(lastLocalInteractSequence, item.seq);
                    Console.WriteLine($"INTERACT_REQ sent #{item.seq}: {item.objId} -> {item.action}");
                }
            }
        }

        if (role == "host" && TryReadWorldStates(localWorldStatePath, out var worldStates, out var _))
        {
            foreach (var item in worldStates)
            {
                if (item.seq > lastLocalWorldSequence)
                {
                    worldCache[item.objId] = (item.state, item.seq);
                    if (peer != null)
                    {
                        var packet = $"{Protocol}|WORLD_STATE|{item.seq}|{playerName}|{item.objId}|{item.state}";
                        SendReliable("STATE", item.seq, packet, now);
                        Console.WriteLine($"WORLD_STATE sent #{item.seq}: {item.objId} = {item.state}");
                    }
                    lastLocalWorldSequence = Math.Max(lastLocalWorldSequence, item.seq);
                }
            }
        }

        if (peer != null)
        {
            for (int i = pendingReliablePackets.Count - 1; i >= 0; i--)
            {
                var pending = pendingReliablePackets[i];
                if (now - pending.LastSentTick >= pending.RetryIntervalMs)
                {
                    if (pending.AttemptCount >= pending.MaxAttempts)
                    {
                        var typeName = pending.Type == "REQ" ? "INTERACT_REQ" : "WORLD_STATE";
                        Console.WriteLine($"Reliable packet {typeName} #{pending.Sequence} exceeded max attempts ({pending.MaxAttempts}), giving up.");
                        lastError = $"retransmit_exhausted_{pending.Type.ToLowerInvariant()}";
                        pendingReliablePackets.RemoveAt(i);
                        continue;
                    }
                    pending.AttemptCount++;
                    pending.LastSentTick = now;
                    Send(udp, peer, pending.RawPacket);
                    var typeName2 = pending.Type == "REQ" ? "INTERACT_REQ" : "WORLD_STATE";
                    Console.WriteLine($"{typeName2} retry #{pending.Sequence} (attempt {pending.AttemptCount})");
                }
            }
        }

        var connected = peer != null && lastPeerPacket != 0 && now - lastPeerPacket < 5000;
        string statusValue;
        if (lastError != null)
        {
            statusValue = $"error|{lastError}|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}";
        }
        else
        {
            statusValue = $"{(connected ? "connected" : "waiting")}|{role}|{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}";
        }
        WriteAtomic(statusPath, statusValue);
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
        try
        {
            await Task.Delay(25, cancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            break;
        }
    }
}

static void Send(UdpClient udp, IPEndPoint endpoint, string value)
{
    var bytes = Encoding.UTF8.GetBytes(value);
    udp.Send(bytes, bytes.Length, endpoint);
}

static string? ReadAllTextShared(string path)
{
    try
    {
        if (!File.Exists(path)) return null;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }
    catch (IOException) { return null; }
    catch (UnauthorizedAccessException) { return null; }
}

static List<string>? ReadAllLinesShared(string path)
{
    try
    {
        if (!File.Exists(path)) return null;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var lines = new List<string>();
        string? line;
        while ((line = reader.ReadLine()) != null)
        {
            lines.Add(line);
        }
        return lines;
    }
    catch (IOException) { return null; }
    catch (UnauthorizedAccessException) { return null; }
}

static bool TryReadState(string path, out string payload, out long sequence)
{
    payload = "";
    sequence = -1;
    var value = ReadAllTextShared(path)?.Trim();
    if (string.IsNullOrEmpty(value)) return false;
    var separator = value.IndexOf('|');
    if (separator < 1 || !long.TryParse(value[..separator], out sequence)) return false;
    payload = value;
    return true;
}

static bool TryReadAction(string path, out string payload, out long sequence)
{
    payload = "";
    sequence = -1;
    var value = ReadAllTextShared(path)?.Trim();
    if (string.IsNullOrEmpty(value)) return false;
    var separator = value.IndexOf('|');
    if (separator < 1 || !long.TryParse(value[..separator], out sequence)) return false;
    var fields = value.Split('|');
    if (fields.Length < 6) return false;
    payload = value;
    return true;
}

static bool TryReadInteracts(string path, out List<(long seq, string objId, string action)> entries, out long maxSeq)
{
    entries = new List<(long, string, string)>();
    maxSeq = -1;
    var lines = ReadAllLinesShared(path);
    if (lines == null || lines.Count == 0) return false;
    foreach (var rawLine in lines)
    {
        var line = rawLine.Trim();
        if (string.IsNullOrEmpty(line)) continue;
        var fields = line.Split('|');
        if (fields.Length < 3) continue;
        if (!long.TryParse(fields[0], out var seq)) continue;
        var objId = fields[1];
        var action = string.Join('|', fields.Skip(2));
        entries.Add((seq, objId, action));
        if (seq > maxSeq) maxSeq = seq;
    }
    return entries.Count > 0;
}

static bool TryReadWorldStates(string path, out List<(long seq, string objId, string state)> entries, out long maxSeq)
{
    entries = new List<(long, string, string)>();
    maxSeq = -1;
    var lines = ReadAllLinesShared(path);
    if (lines == null || lines.Count == 0) return false;
    foreach (var rawLine in lines)
    {
        var line = rawLine.Trim();
        if (string.IsNullOrEmpty(line)) continue;
        var fields = line.Split('|');
        if (fields.Length < 3) continue;
        if (!long.TryParse(fields[0], out var seq)) continue;
        var objId = fields[1];
        var state = string.Join('|', fields.Skip(2));
        entries.Add((seq, objId, state));
        if (seq > maxSeq) maxSeq = seq;
    }
    return entries.Count > 0;
}

static bool TryReadPosition(string path, out double x, out double y, out double z)
{
    x = y = z = 0;
    var text = ReadAllTextShared(path)?.Trim();
    if (string.IsNullOrEmpty(text)) return false;
    var fields = text.Split('|');
    return fields.Length >= 4
        && double.TryParse(fields[1], NumberStyles.Float, CultureInfo.InvariantCulture, out x)
        && double.TryParse(fields[2], NumberStyles.Float, CultureInfo.InvariantCulture, out y)
        && double.TryParse(fields[3], NumberStyles.Float, CultureInfo.InvariantCulture, out z);
}

static void WriteAtomic(string path, string value)
{
    var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
        using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
        using (var writer = new StreamWriter(stream, Encoding.UTF8))
        {
            writer.Write(value);
        }
        File.Move(temporary, path, true);
    }
    catch (IOException) { }
    catch (UnauthorizedAccessException) { }
    finally
    {
        try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
    }
}

class SlidingSet<T> where T : notnull
{
    private readonly int _capacity;
    private readonly HashSet<T> _set = new();
    private readonly Queue<T> _queue = new();

    public SlidingSet(int capacity = 2048)
    {
        _capacity = capacity;
    }

    public bool Add(T item)
    {
        if (_set.Contains(item))
            return false;

        if (_queue.Count >= _capacity)
        {
            var oldest = _queue.Dequeue();
            _set.Remove(oldest);
        }

        _queue.Enqueue(item);
        _set.Add(item);
        return true;
    }

    public bool Contains(T item) => _set.Contains(item);

    public void Clear()
    {
        _set.Clear();
        _queue.Clear();
    }

    public int Count => _set.Count;
}

class PendingReliablePacket
{
    public string Type { get; set; } = "";
    public long Sequence { get; set; }
    public string RawPacket { get; set; } = "";
    public long LastSentTick { get; set; }
    public int AttemptCount { get; set; } = 1;
    public int MaxAttempts { get; set; } = 25;
    public long RetryIntervalMs { get; set; } = 100;
}
